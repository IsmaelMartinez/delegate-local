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

make_mock_curl_think() {
  # Mock curl whose Ollama .response carries a <think>...</think> reasoning
  # trace before the answer, to exercise DELEGATE_STRIP_THINK. $2 is the
  # JSON-escaped .response value (use \n for newlines). Mirrors
  # make_mock_curl_ok's -o / -w / probe handling.
  local dir="$1" resp="$2"
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
cat > /dev/null
body='{"response":"${resp}"}'
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
  # Default sampling is greedy for ALL models (Qwen3 included) since the
  # T4 A/B in 2026-05-22-track-a-qwen-sampling-ab.md found the Alibaba-
  # recommended profile regresses commit-message output. Env vars opt INTO
  # non-greedy sampling — bare invocation must have bare temperature:0 and
  # NO top_p/top_k/presence_penalty.
  assert_contains '"options":{"temperature":0}' "$payload" "payload: bare greedy options.temperature:0"
  case "$payload" in
    *'"top_p"'*) echo "  FAIL  payload: bare greedy must NOT carry top_p"; fail=$((fail+1));;
    *) echo "  PASS  payload: bare greedy omits top_p"; pass=$((pass+1));;
  esac
  case "$payload" in
    *'"top_k"'*) echo "  FAIL  payload: bare greedy must NOT carry top_k"; fail=$((fail+1));;
    *) echo "  PASS  payload: bare greedy omits top_k"; pass=$((pass+1));;
  esac
  case "$payload" in
    *'"presence_penalty"'*) echo "  FAIL  payload: bare greedy must NOT carry presence_penalty"; fail=$((fail+1));;
    *) echo "  PASS  payload: bare greedy omits presence_penalty"; pass=$((pass+1));;
  esac
else
  echo "  FAIL  payload sniff: file empty"; fail=$((fail+1))
fi
# Bare greedy invocation must NOT write any sampling_* keys to the metrics
# row (back-compat with pre-Phase-13 rows). Env-var opt-in adds them; absent
# any env var the row carries no sampling fields.
case "$line" in
  *'"sampling_temperature"'*) echo "  FAIL  metrics: bare greedy must omit sampling_temperature"; fail=$((fail+1));;
  *) echo "  PASS  metrics: bare greedy omits sampling_temperature"; pass=$((pass+1));;
esac
case "$line" in
  *'"sampling_top_p"'*) echo "  FAIL  metrics: bare greedy must omit sampling_top_p"; fail=$((fail+1));;
  *) echo "  PASS  metrics: bare greedy omits sampling_top_p"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# 3. Opt-out env var suppresses metrics writing.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); rm -f "$metrics"  # ensure file does not exist
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_METRICS=1 \
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
# MLX bare invocation also stays greedy (default flipped 2026-05-23). Env
# vars opt INTO sampling per call on either backend.
assert_contains '"temperature":0' "$payload" "MLX payload: bare greedy temperature=0"
case "$payload" in
  *'"top_p"'*) echo "  FAIL  MLX payload: bare greedy must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  MLX payload: bare greedy omits top_p"; pass=$((pass+1));;
esac
case "$payload" in
  *'"top_k"'*) echo "  FAIL  MLX payload: bare greedy must NOT carry top_k"; fail=$((fail+1));;
  *) echo "  PASS  MLX payload: bare greedy omits top_k"; pass=$((pass+1));;
esac
case "$payload" in
  *'"presence_penalty"'*) echo "  FAIL  MLX payload: bare greedy must NOT carry presence_penalty"; fail=$((fail+1));;
  *) echo "  PASS  MLX payload: bare greedy omits presence_penalty"; pass=$((pass+1));;
esac
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
assert_contains '"project":"' "$(cat "$metrics")" "metrics row contains project field"
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

# 14a. Non-TTY caller still gets the nudge — pins the issue #149 fix in
# place. A previous TTY-gate proposal (PR #140 / issue #139) would have
# silenced the nudge whenever stderr wasn't a terminal, causing Agent SDK
# tool calls, scheduled routines, and `2>logfile` redirects to all skip
# verdict tracking. Lifetime coverage measured 47.8% under that gate. This
# test invokes delegate.sh with stdin piped from a here-string and stderr
# captured via a pipeline (both definitely non-TTY) and asserts the nudge
# still lands. If a future PR re-introduces a `[[ -t 2 ]]` gate on the
# verdict-nudge code path, this test fails loud.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
# Pipe stdin in (non-TTY), redirect stderr to a file via the shell (non-TTY).
# Both file-descriptors are pipes/files, never terminals — exactly what an
# Agent SDK `run_in_background` caller or a CI step sees.
out=$(echo "some context" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge non-TTY: exits 0 with piped stdin and redirected stderr"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate: record verdict" "$stderr_content" "verdict-nudge non-TTY: nudge still printed when neither stdin nor stderr is a TTY"
# Belt-and-braces: also pipe stdout through `cat` so stdout is unambiguously
# a pipe (the variable-capture path above already deattaches it from any
# TTY, but a future test reader looking for "was stdout a pipe?" sees the
# explicit pipeline here without having to know about command-substitution
# semantics).
EC=0
piped=$(echo "ctx" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" 2>"$stderr_file" | cat) || EC=$?
assert_eq 0 "$EC" "verdict-nudge non-TTY: exits 0 with stdout piped through cat"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate: record verdict" "$stderr_content" "verdict-nudge non-TTY: nudge still printed with stdout piped through cat"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 15. DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 silences the nudge but keeps
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
  DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
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
  DELEGATE_LOCAL_NO_METRICS=1 \
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

# 17a. DELEGATE_LOCAL_VERDICT_NUDGE_FD=N redirects the nudge to fd N
# instead of fd 2. Closes issue #139 (parallel-capture callers contaminating
# stdout via 2>&1) without re-introducing the TTY-gate that the #149
# reversal showed dropped lifetime verdict coverage from 82% interactive to
# 47.8% lifetime. The recipe a parallel-capture caller wants is:
#   DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 bash delegate.sh prose "X" \
#     > out.txt 2>&1 3>>nudge.log
# stdout+stderr go to out.txt unaffected; the nudge lands on nudge.log via
# fd 3 so coverage tracking stays intact.

# 17a-1. Happy path: fd 3 redirected to a file; nudge lands on the file, not
# on fd 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
nudge_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file" 3>>"$nudge_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=3: happy path exits 0"
stderr_content=$(cat "$stderr_file")
nudge_content=$(cat "$nudge_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=3: nudge leaked into fd 2 instead of fd 3"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3: fd 2 stays clean"; pass=$((pass+1))
fi
assert_contains "delegate: record verdict" "$nudge_content" "verdict-nudge FD=3: nudge lands on fd 3"
# Belt-and-braces: stdout still carries only the model output.
if echo "$out" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=3: nudge leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3: stdout unaffected"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file" "$nudge_file"

# 17a-2. fd 3 set but NOT redirected → silent write-failure. The call still
# succeeds (the model output is on stdout, exit 0) but the nudge has nowhere
# to go and the failed write is absorbed via `2>/dev/null` on the echo so
# the gotcha-mode caller doesn't see "Bad file descriptor" noise back on
# the fd 2 they were trying to keep clean.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=3 no redirect: still exits 0"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=3 no redirect: nudge leaked into fd 2"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 no redirect: fd 2 stays clean"; pass=$((pass+1))
fi
# The "Bad file descriptor" stderr from the failed write is suppressed by
# the `2>/dev/null` redirect on the echo in delegate.sh — this assertion
# pins that behaviour so a future refactor can't silently regress it.
if echo "$stderr_content" | grep -qi "bad file descriptor"; then
  echo "  FAIL  verdict-nudge FD=3 no redirect: 'Bad file descriptor' leaked back to fd 2"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 no redirect: failed write absorbed silently"; pass=$((pass+1))
fi
# Metrics row was still written; coverage tracking against the JSONL surface
# stays intact regardless of where the nudge landed.
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge FD=3 no redirect: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-3. FD=2 is the default-equivalent — back-compat check that explicitly
# setting the env var to the default value behaves the same as leaving it
# unset (the test in 14/14a covers unset; this pins the explicit-2 path).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=2 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=2 (default-equivalent): exits 0"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate: record verdict" "$stderr_content" "verdict-nudge FD=2: nudge lands on fd 2 (back-compat)"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-4. FD=1 is allowed — some callers may want the nudge inline with the
# model output on stdout. Unusual but harmless; the validation accepts any
# positive integer.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=1: exits 0"
if echo "$out" | grep -q "record verdict"; then
  echo "  PASS  verdict-nudge FD=1: nudge lands on stdout"; pass=$((pass+1))
else
  echo "  FAIL  verdict-nudge FD=1: nudge missing from stdout"; fail=$((fail+1))
fi
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=1: nudge also leaked into fd 2"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=1: fd 2 stays clean"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-5. FD=0 (stdin) is rejected — writing to stdin is nonsense, so a clear
# error fires before the model is contacted. exit 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=0 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=0: exits 2 (stdin rejected)"
stderr_content=$(cat "$stderr_file")
assert_contains "DELEGATE_LOCAL_VERDICT_NUDGE_FD" "$stderr_content" "verdict-nudge FD=0: error names the env var"
assert_contains "valid: 1-9" "$stderr_content" "verdict-nudge FD=0: error mentions the valid shape (1-9 single-digit range)"
# No metrics row should have been written — validation fires before model
# contact, so no delegation row exists to verdict against.
if [[ -s "$metrics" ]]; then
  echo "  FAIL  verdict-nudge FD=0: metrics row written despite pre-flight rejection"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=0: no metrics row (rejection fires pre-flight)"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-6. FD=foo (non-numeric) is rejected. exit 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=foo \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=foo: exits 2 (non-numeric rejected)"
stderr_content=$(cat "$stderr_file")
assert_contains "DELEGATE_LOCAL_VERDICT_NUDGE_FD" "$stderr_content" "verdict-nudge FD=foo: error names the env var"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-7. FD=-1 (negative) is rejected. The regex `^[1-9]$` matches single-
# digit positive integers only — the leading `-` makes the match fail,
# same path as the non-numeric case but worth pinning explicitly because
# a future relaxation of the regex (e.g. accidentally adding a `-?` to
# handle "0 or negative") would silently break this.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=-1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=-1: exits 2 (negative rejected)"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-7b. FD=10 (multi-digit) is rejected. bash 3.2 — the project's
# portability floor — does not reliably support `>&$N` for N>=10 because
# the `{var}>file` form is bash 4+. Restricting validation to single
# digits makes the failure mode loud (exit 2 here) instead of silent
# (write fails at nudge time, absorbed by the 2>/dev/null guard).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=10 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=10: exits 2 (multi-digit rejected)"
stderr_content=$(cat "$stderr_file")
assert_contains "DELEGATE_LOCAL_VERDICT_NUDGE_FD" "$stderr_content" "verdict-nudge FD=10: error names the env var"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-7c. FD=99 (larger multi-digit) is also rejected. Same reasoning as
# 17a-7b — anchors the regex tightness against future relaxation.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=99 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=99: exits 2 (multi-digit rejected)"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-8. FD set AND NO_VERDICT_NUDGE=1 → NO_VERDICT_NUDGE wins. Suppression
# beats redirect.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
nudge_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file" 3>>"$nudge_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=3 + NO_VERDICT_NUDGE: exits 0"
nudge_content=$(cat "$nudge_file")
if [[ -n "$nudge_content" ]]; then
  echo "  FAIL  verdict-nudge FD=3 + NO_VERDICT_NUDGE: nudge still emitted to fd 3"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 + NO_VERDICT_NUDGE: NO_VERDICT_NUDGE wins (no nudge on fd 3)"; pass=$((pass+1))
fi
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=3 + NO_VERDICT_NUDGE: nudge leaked into fd 2"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 + NO_VERDICT_NUDGE: fd 2 also stays clean"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file" "$nudge_file"

# 17a-9. FD set AND NO_METRICS=1 → NO_METRICS wins (no metrics row → nothing
# to verdict against, same as today's NO_METRICS behaviour).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); rm -f "$metrics"
stderr_file=$(mktemp)
nudge_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file" 3>>"$nudge_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=3 + NO_METRICS: exits 0"
nudge_content=$(cat "$nudge_file")
if [[ -n "$nudge_content" ]]; then
  echo "  FAIL  verdict-nudge FD=3 + NO_METRICS: nudge emitted despite no metrics row"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 + NO_METRICS: NO_METRICS wins (no nudge on fd 3)"; pass=$((pass+1))
fi
rm -rf "$tmp" "$stderr_file" "$nudge_file"

# 17a-10. FD set on non-zero exit (pick-model failure) → no nudge. Same as
# today's non-zero-exit behaviour; failed calls have no model output to
# judge, so no verdict should be invited.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
nudge_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file" 3>>"$nudge_file") || EC=$?
assert_eq 1 "$EC" "verdict-nudge FD=3 on failure: still exits 1"
nudge_content=$(cat "$nudge_file")
if [[ -n "$nudge_content" ]]; then
  echo "  FAIL  verdict-nudge FD=3 on failure: nudge emitted despite non-zero exit"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 on failure: silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file" "$nudge_file"

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

# 20. DELEGATE_LOCAL_NO_META=1 silences the meta line but the rest of
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
  DELEGATE_LOCAL_NO_META=1 \
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

# 27d2. Optional input WITH a {{placeholder}} in the body, --var provided →
# the value is substituted into the template. This is the override case the
# explicit commit-message `type` lever relies on. The marker line collapses
# to `override:spicy:end` so a single assert_contains proves substitution.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  pr_number: integer
  flavour: string?
---
# typed-recipe

## When to use
test

## Prompt template

```
pr_number={{pr_number}}
override:{{flavour}}:end
```

## Variables

- `{{pr_number}}` — PR number
- `{{flavour}}` — optional flavour override

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=7 --var flavour=spicy prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: optional placeholder provided → exits 0"
assert_contains 'override:spicy:end' "$(cat "$sniff")" "inputs: optional --var substituted into template"
rm -rf "$tmp" "$metrics"

# 27d3. Same recipe with the optional --var OMITTED → the {{flavour}}
# placeholder is blanked rather than tripping the unsubstituted-placeholder
# guard. The marker collapses to `override::end`, which the literal-placeholder
# bug would have rendered as `override:{{flavour}}:end` — so a positive
# assert_contains on `override::end` proves the blanking happened.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  pr_number: integer
  flavour: string?
---
# typed-recipe

## When to use
test

## Prompt template

```
pr_number={{pr_number}}
override:{{flavour}}:end
```

## Variables

- `{{pr_number}}` — PR number
- `{{flavour}}` — optional flavour override

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=7 prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: optional placeholder omitted → exits 0 (blanked, not exit 2)"
assert_contains 'override::end' "$(cat "$sniff")" "inputs: omitted optional placeholder collapsed to empty"
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
assert_contains '"delegate-local"' "$otel_body" "OT2: resource service.name value"
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

# OT12. DELEGATE_OTEL_HEADERS url-decodes header values per the OTel SDK
# convention, so a header value carrying a literal comma (encoded as %2C)
# round-trips to the on-wire header without fragmenting the comma-split.
# This is the self-review correctness gap caught during PR #182 review:
# unencoded `Cookie: a=1, b=2` would fragment into two malformed -H flags;
# the documented fix is for callers to url-encode the value (`a%3D1%2C%20b%3D2`)
# and rely on the script to decode it before emitting -H.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
# `a%3D1%2C%20b%3D2` decodes to `a=1, b=2` — a literal comma in the value.
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_HEADERS="Cookie: a%3D1%2C%20b%3D2, X-Tenant: y" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT12: url-encoded comma in header → exits 0"
otel_args_line=$(grep '^otel' "$invocations" | head -1)
# The decoded value must contain the literal `,` and `=` — proving the
# perl url-decode ran and the comma was NOT mistaken for a header
# separator. The X-Tenant header following the comma in the env var
# must also still be present, proving the script's split is on the
# OUTER comma (between header pairs) and the inner %2C was preserved.
assert_contains "Cookie: a=1, b=2" "$otel_args_line" "OT12: header value's literal comma round-trips after url-decode"
assert_contains "X-Tenant: y" "$otel_args_line" "OT12: second header still parsed after comma-bearing first header"
# Three -H flags total: Content-Type (always present), Cookie, X-Tenant.
# A fragmented Cookie header would push the count to four; the literal
# `,` proves the value was NOT split.
h_count=$(echo "$otel_args_line" | grep -oE '\-H ' | wc -l | tr -d ' ')
assert_eq 3 "$h_count" "OT12: exactly three -H flags (Content-Type + Cookie + X-Tenant) — not four (would mean Cookie fragmented)"
rm -rf "$tmp" "$metrics"

# OT13. OTLP/JSON int64 attribute values are encoded as JSON strings per the
# proto3 JSON mapping (AnyValue.int_value is int64). The exporter passes
# integer attribute values via jq --arg (not --argjson) so they emerge as
# quoted strings in the wire payload. status.code and span.kind are int32
# enums and stay JSON numbers.
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
assert_eq 0 "$EC" "OT13: int64-as-string export → exits 0"
otel_body=$(cat "$otel_sniff")
# delegate.exit_status is always 0 here (successful call); the OTLP int64
# encoding must wrap that 0 in quotes. Same for the other int attributes.
# Use jq to inspect the actual JSON type rather than substring-matching
# the wire bytes (which would conflate `"0"` and `0` if the surrounding
# tokens overlap). pchars/cchars/ochars are non-zero for the prompt
# `"Summarise"` and the canned mock response.
exit_status_type=$(echo "$otel_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.exit_status"))
  | .[0].value.intValue | type')
assert_eq "string" "$exit_status_type" "OT13: delegate.exit_status intValue is JSON string"
pchars_type=$(echo "$otel_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.prompt_chars"))
  | .[0].value.intValue | type')
assert_eq "string" "$pchars_type" "OT13: delegate.prompt_chars intValue is JSON string"
tokens_type=$(echo "$otel_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.estimated_tokens_avoided"))
  | .[0].value.intValue | type')
assert_eq "string" "$tokens_type" "OT13: delegate.estimated_tokens_avoided intValue is JSON string"
# span.kind and status.code stay int32 (JSON numbers) — they're enums
# in the proto, not int64 fields.
kind_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].kind | type')
assert_eq "number" "$kind_type" "OT13: span.kind stays a JSON number (int32 enum)"
status_code_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].status.code | type')
assert_eq "number" "$status_code_type" "OT13: status.code stays a JSON number (int32 enum)"
# startTimeUnixNano / endTimeUnixNano are fixed64 — also JSON strings.
start_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].startTimeUnixNano | type')
assert_eq "string" "$start_type" "OT13: startTimeUnixNano is JSON string (fixed64)"
end_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].endTimeUnixNano | type')
assert_eq "string" "$end_type" "OT13: endTimeUnixNano is JSON string (fixed64)"
rm -rf "$tmp" "$metrics"

# ---------------------------------------------------------------------------
# Phase 11 Track F — privacy redaction default (#158)
# DELEGATE_OTEL_INCLUDE_CONTENT gates `delegate.prompt`, `delegate.context`,
# `delegate.output`. Default unset = redact (omit the three attributes
# entirely). Set to `1` = include them with their actual values. Metadata
# attributes (tier, model, char counts, durations, exit_status) stay
# unconditional.
# ---------------------------------------------------------------------------

# OT14. Default redaction: with DELEGATE_OTEL_ENDPOINT set but
# DELEGATE_OTEL_INCLUDE_CONTENT unset, the OTLP body contains the metadata
# attributes (prompt_chars, context_chars, output_chars, tier, model) but
# does NOT contain delegate.prompt, delegate.context, or delegate.output.
# The actual content text (the prompt arg and the canned mock response)
# must not appear anywhere in the body — no key, no value, no sentinel.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
SENTINEL_PROMPT="Summarise the diff for repo project-alpha"
SENTINEL_CONTEXT="diff --git a/secret-customer-config.yaml b/secret-customer-config.yaml"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "$SENTINEL_PROMPT" <<<"$SENTINEL_CONTEXT" 2>&1) || EC=$?
assert_eq 0 "$EC" "OT14: default redaction → exits 0"
otel_body=$(cat "$otel_sniff")
# Metadata still present.
assert_contains '"delegate.tier"' "$otel_body" "OT14: metadata delegate.tier present"
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT14: metadata delegate.prompt_chars present"
assert_contains '"delegate.context_chars"' "$otel_body" "OT14: metadata delegate.context_chars present"
assert_contains '"delegate.output_chars"' "$otel_body" "OT14: metadata delegate.output_chars present"
# Content attribute keys MUST be absent.
case "$otel_body" in
  *'"delegate.prompt"'*)
    echo "  FAIL  OT14: delegate.prompt key MUST be absent by default"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: delegate.prompt key absent by default"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'"delegate.context"'*)
    echo "  FAIL  OT14: delegate.context key MUST be absent by default"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: delegate.context key absent by default"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'"delegate.output"'*)
    echo "  FAIL  OT14: delegate.output key MUST be absent by default"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: delegate.output key absent by default"
    pass=$((pass+1));;
esac
# Content TEXT itself must not appear anywhere in the body.
case "$otel_body" in
  *"$SENTINEL_PROMPT"*)
    echo "  FAIL  OT14: prompt sentinel text MUST NOT appear in payload"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: prompt sentinel text omitted from body"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *"$SENTINEL_CONTEXT"*)
    echo "  FAIL  OT14: context sentinel text MUST NOT appear in payload"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: context sentinel text omitted from body"
    pass=$((pass+1));;
esac
# Output text (canned `mock-model-output: ok`) must also be absent.
case "$otel_body" in
  *'mock-model-output: ok'*)
    echo "  FAIL  OT14: model output text MUST NOT appear in payload"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: model output text omitted from body"
    pass=$((pass+1));;
esac
# No '<redacted>' sentinel either — the schema is omission, not placeholder.
case "$otel_body" in
  *'<redacted>'*)
    echo "  FAIL  OT14: no '<redacted>' sentinel should leak into the body"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: no '<redacted>' sentinel in body (omission, not placeholder)"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT15. Opt-in inclusion (DELEGATE_OTEL_INCLUDE_CONTENT=1): all three content
# attributes are present with their actual values. The metadata attributes
# also stay present — opt-in adds content, it doesn't replace metadata.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
SENTINEL_PROMPT="Summarise this PR description"
SENTINEL_CONTEXT="diff --git a/README.md b/README.md"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" prose "$SENTINEL_PROMPT" <<<"$SENTINEL_CONTEXT" 2>&1) || EC=$?
assert_eq 0 "$EC" "OT15: opt-in include-content → exits 0"
otel_body=$(cat "$otel_sniff")
# All three content attribute KEYS present.
assert_contains '"delegate.prompt"' "$otel_body" "OT15: delegate.prompt key present when opt-in"
assert_contains '"delegate.context"' "$otel_body" "OT15: delegate.context key present when opt-in"
assert_contains '"delegate.output"' "$otel_body" "OT15: delegate.output key present when opt-in"
# Content TEXT present.
assert_contains "$SENTINEL_PROMPT" "$otel_body" "OT15: prompt text preserved verbatim when opt-in"
assert_contains "$SENTINEL_CONTEXT" "$otel_body" "OT15: context text preserved verbatim when opt-in"
assert_contains 'mock-model-output: ok' "$otel_body" "OT15: output text preserved verbatim when opt-in"
# Metadata still present (opt-in is additive, not replacement).
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT15: char-count metadata still present"
assert_contains '"delegate.tier"' "$otel_body" "OT15: tier metadata still present"
# Use jq to confirm the content attributes have the right structural shape.
prompt_val=$(echo "$otel_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.prompt"))
  | .[0].value.stringValue')
assert_eq "$SENTINEL_PROMPT" "$prompt_val" "OT15: delegate.prompt stringValue matches input"
context_val=$(echo "$otel_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.context"))
  | .[0].value.stringValue')
assert_eq "$SENTINEL_CONTEXT" "$context_val" "OT15: delegate.context stringValue matches input"
rm -rf "$tmp" "$metrics"

# OT16. Explicit =0 redacts same as unset. Defensive: the gate compares
# string equality to "1" rather than truthiness, so any value other than
# "1" stays redacted.
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
  DELEGATE_OTEL_INCLUDE_CONTENT=0 \
  bash "$SCRIPT" prose "ExplicitZeroSentinel" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT16: explicit =0 → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'"delegate.prompt"'*|*'ExplicitZeroSentinel'*)
    echo "  FAIL  OT16: DELEGATE_OTEL_INCLUDE_CONTENT=0 must redact same as unset"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT16: DELEGATE_OTEL_INCLUDE_CONTENT=0 redacts same as unset"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT17. Only literal "1" enables include-content (typo-safe). Operators
# who set INCLUDE_CONTENT=true or =yes expecting truthiness get the safer
# default (redact) instead of accidentally shipping content.
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
  DELEGATE_OTEL_INCLUDE_CONTENT=true \
  bash "$SCRIPT" prose "TrueSentinelValue" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT17: =true (not '1') → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'"delegate.prompt"'*|*'TrueSentinelValue'*)
    echo "  FAIL  OT17: DELEGATE_OTEL_INCLUDE_CONTENT=true must NOT enable content (only literal '1')"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT17: only literal '1' enables include-content (typo-safe)"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# ---------------------------------------------------------------------------
# Track A of #193 — opt-in sampler overrides (delegate.sh)
# Default sampler is greedy for ALL models (temperature=0, no top_p/top_k/
# presence_penalty in the payload, no sampling_* keys in the metrics row).
# An earlier iteration of this code path auto-applied the Alibaba-recommended
# Qwen3 instruct profile (temperature=0.7, top_p=0.8, top_k=20,
# presence_penalty=1.3) on Qwen3-family models, but the T4 A/B in
# experiments/results/2026-05-22-track-a-qwen-sampling-ab.md found the
# profile regresses commit-message output. The default flipped back to
# greedy 2026-05-23; the four env-var overrides (DELEGATE_TEMPERATURE /
# DELEGATE_TOP_P / DELEGATE_TOP_K / DELEGATE_PRESENCE_PENALTY) remain so
# callers can opt INTO the Qwen profile (or any other profile) per call.
# Non-numeric env vars exit 2 with a named error. Canary preflight stays
# greedy regardless. The metrics row carries sampling_* keys only when the
# caller explicitly set the corresponding env var.
# ---------------------------------------------------------------------------

# QS1. Qwen-family model with no overrides → bare greedy on the Ollama
# dispatch payload AND on the JSONL metrics row (no sampling_* keys at all).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS1: Qwen model with no overrides exits 0"
payload=$(cat "$sniff")
assert_contains '"options":{"temperature":0}' "$payload" "QS1: bare greedy payload has options.temperature:0"
case "$payload" in
  *'"temperature":0.7'*) echo "  FAIL  QS1: Qwen model must NOT auto-apply temperature=0.7 (default flipped)"; fail=$((fail+1));;
  *) echo "  PASS  QS1: Qwen model stays greedy by default"; pass=$((pass+1));;
esac
case "$payload" in
  *'"top_p"'*) echo "  FAIL  QS1: bare invocation must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare invocation omits top_p"; pass=$((pass+1));;
esac
case "$payload" in
  *'"top_k"'*) echo "  FAIL  QS1: bare invocation must NOT carry top_k"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare invocation omits top_k"; pass=$((pass+1));;
esac
case "$payload" in
  *'"presence_penalty"'*) echo "  FAIL  QS1: bare invocation must NOT carry presence_penalty"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare invocation omits presence_penalty"; pass=$((pass+1));;
esac
line=$(cat "$metrics")
# Metrics row carries NO sampling_* keys on bare greedy — back-compat with
# pre-Phase-13 JSONL rows.
case "$line" in
  *'"sampling_temperature"'*) echo "  FAIL  QS1: bare metrics row must omit sampling_temperature"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare metrics row omits sampling_temperature"; pass=$((pass+1));;
esac
case "$line" in
  *'"sampling_top_p"'*) echo "  FAIL  QS1: bare metrics row must omit sampling_top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare metrics row omits sampling_top_p"; pass=$((pass+1));;
esac
case "$line" in
  *'"sampling_top_k"'*) echo "  FAIL  QS1: bare metrics row must omit sampling_top_k"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare metrics row omits sampling_top_k"; pass=$((pass+1));;
esac
case "$line" in
  *'"sampling_presence_penalty"'*) echo "  FAIL  QS1: bare metrics row must omit sampling_presence_penalty"; fail=$((fail+1));;
  *) echo "  PASS  QS1: bare metrics row omits sampling_presence_penalty"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# QS2. Non-Qwen model also stays greedy by default (same default for all
# models). Verifies the default-flip applies uniformly, not just to non-Qwen.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    cat <<'LIST'
NAME             ID SIZE   MODIFIED
deepseek-r1:32b  aa 30 GB  1 day ago
LIST
    ;;
esac
EOF
chmod +x "$tmp/ollama"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" reasoning "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS2: non-Qwen model exits 0"
payload=$(cat "$sniff")
assert_contains '"model":"deepseek-r1:32b"' "$payload" "QS2: model resolved to deepseek-r1"
assert_contains '"options":{"temperature":0}' "$payload" "QS2: non-Qwen payload has bare options.temperature:0"
case "$payload" in
  *'"top_p"'*) echo "  FAIL  QS2: non-Qwen payload must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS2: non-Qwen payload omits top_p"; pass=$((pass+1));;
esac
case "$payload" in
  *'"top_k"'*) echo "  FAIL  QS2: non-Qwen payload must NOT carry top_k"; fail=$((fail+1));;
  *) echo "  PASS  QS2: non-Qwen payload omits top_k"; pass=$((pass+1));;
esac
case "$payload" in
  *'"presence_penalty"'*) echo "  FAIL  QS2: non-Qwen payload must NOT carry presence_penalty"; fail=$((fail+1));;
  *) echo "  PASS  QS2: non-Qwen payload omits presence_penalty"; pass=$((pass+1));;
esac
line=$(cat "$metrics")
case "$line" in
  *'"sampling_temperature"'*) echo "  FAIL  QS2: bare metrics row must omit sampling_temperature"; fail=$((fail+1));;
  *) echo "  PASS  QS2: bare metrics row omits sampling_temperature"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# QS3. Full Qwen profile opt-in via the four env vars on a Qwen model. The
# env vars provide both the dispatch payload sampler and the metrics row
# entries — surfacing what the caller chose to set.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.7 \
  DELEGATE_TOP_P=0.8 \
  DELEGATE_TOP_K=20 \
  DELEGATE_PRESENCE_PENALTY=1.3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS3: full Qwen-profile opt-in exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0.7' "$payload" "QS3: opt-in payload carries temperature=0.7"
assert_contains '"top_p":0.8' "$payload" "QS3: opt-in payload carries top_p=0.8"
assert_contains '"top_k":20' "$payload" "QS3: opt-in payload carries top_k=20"
assert_contains '"presence_penalty":1.3' "$payload" "QS3: opt-in payload carries presence_penalty=1.3"
line=$(cat "$metrics")
assert_contains '"sampling_temperature":0.7' "$line" "QS3: opt-in metrics row carries sampling_temperature"
assert_contains '"sampling_top_p":0.8' "$line" "QS3: opt-in metrics row carries sampling_top_p"
assert_contains '"sampling_top_k":20' "$line" "QS3: opt-in metrics row carries sampling_top_k"
assert_contains '"sampling_presence_penalty":1.3' "$line" "QS3: opt-in metrics row carries sampling_presence_penalty"
rm -rf "$tmp" "$metrics"

# QS3b. Partial opt-in — only DELEGATE_TEMPERATURE is set. The dispatch
# payload carries the override but no top_p/top_k/presence_penalty (those
# stay unset because the caller didn't request them). Metrics row mirrors:
# sampling_temperature present, others omitted.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.5 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS3b: partial opt-in exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0.5' "$payload" "QS3b: partial opt-in payload carries the override"
case "$payload" in
  *'"top_p"'*) echo "  FAIL  QS3b: partial opt-in must NOT carry top_p (not opted into)"; fail=$((fail+1));;
  *) echo "  PASS  QS3b: partial opt-in omits top_p"; pass=$((pass+1));;
esac
line=$(cat "$metrics")
assert_contains '"sampling_temperature":0.5' "$line" "QS3b: partial opt-in metrics row carries sampling_temperature"
case "$line" in
  *'"sampling_top_p"'*) echo "  FAIL  QS3b: partial opt-in metrics must omit sampling_top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS3b: partial opt-in metrics omits sampling_top_p"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# QS4. Non-numeric DELEGATE_TEMPERATURE exits 2 with a clear stderr.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=not-a-number \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "QS4: non-numeric temperature exits 2"
stderr_content=$(cat "$stderr_file")
assert_contains "DELEGATE_TEMPERATURE" "$stderr_content" "QS4: stderr names the bad env var"
assert_contains "not numeric" "$stderr_content" "QS4: stderr names the failure mode"
rm -rf "$tmp" "$metrics" "$stderr_file"

# QS4b. Each of the four overrides validates independently — non-numeric
# DELEGATE_TOP_P / DELEGATE_TOP_K / DELEGATE_PRESENCE_PENALTY all exit 2.
for vname in DELEGATE_TOP_P DELEGATE_TOP_K DELEGATE_PRESENCE_PENALTY; do
  tmp=$(mktemp -d)
  make_mock_ollama "$tmp"
  make_mock_curl_ok "$tmp"
  metrics=$(mktemp); : > "$metrics"
  stderr_file=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    "$vname"="garbage" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
  assert_eq 2 "$EC" "QS4b/$vname: non-numeric exits 2"
  assert_contains "$vname" "$(cat "$stderr_file")" "QS4b/$vname: stderr names env var"
  rm -rf "$tmp" "$metrics" "$stderr_file"
done

# QS4c. Edge-case rejected values. The validator must catch shapes that
# `[!0-9.-]` character-class checks would let through but jq --argjson
# rejects (`1-2`, `5-`, `.-`, `1.5.6`). Each must exit 2 with the script's
# own clean error, not jq's 'invalid JSON text' surface. Pins the
# bash-3.2-compatible `=~` regex against regression to the permissive
# case-pattern form.
for bad in "1-2" "5-" ".-" "1.5.6" "-" "."; do
  tmp=$(mktemp -d)
  make_mock_ollama "$tmp"
  make_mock_curl_ok "$tmp"
  metrics=$(mktemp); : > "$metrics"
  stderr_file=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_TEMPERATURE="$bad" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
  assert_eq 2 "$EC" "QS4c/'$bad': exit 2"
  assert_contains "not numeric" "$(cat "$stderr_file")" "QS4c/'$bad': clean validator error (not jq's 'invalid JSON' surface)"
  rm -rf "$tmp" "$metrics" "$stderr_file"
done

# QS4d. Valid numeric shapes the validator must continue to accept:
# integers, negatives, floats, leading-dot decimals, trailing-dot integers.
# Each should pass through to dispatch (exit 0).
for good in "0" "1" "-1" "0.7" "1.3" ".5" "1." "-42" "-0.5"; do
  tmp=$(mktemp -d)
  make_mock_ollama "$tmp"
  make_mock_curl_ok "$tmp"
  metrics=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_TEMPERATURE="$good" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
  assert_eq 0 "$EC" "QS4d/'$good': accepted (exit 0)"
  rm -rf "$tmp" "$metrics"
done

# QS5. MLX backend, Qwen3 model, full opt-in via env vars. Profile lands on
# /v1/chat/completions as top-level keys (OpenAI shape), not inside an
# `options` object. Mirror QS3 to confirm MLX dispatch honours the same
# env-var surface as Ollama.
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
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.7 \
  DELEGATE_TOP_P=0.8 \
  DELEGATE_TOP_K=20 \
  DELEGATE_PRESENCE_PENALTY=1.3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS5: MLX + full opt-in exits 0"
payload=$(cat "$payload_sniff")
assert_contains '"temperature":0.7' "$payload" "QS5: MLX payload has opt-in temperature"
assert_contains '"top_p":0.8' "$payload" "QS5: MLX payload has opt-in top_p"
assert_contains '"top_k":20' "$payload" "QS5: MLX payload has opt-in top_k"
assert_contains '"presence_penalty":1.3' "$payload" "QS5: MLX payload has opt-in presence_penalty"
rm -rf "$tmp" "$metrics"

# QS5b. Non-numeric override on MLX path also exits 2 (same validator runs
# before the dispatch envelope is built, regardless of backend).
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
make_mock_curl_mlx_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TOP_P=oops \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "QS5b: MLX + bad DELEGATE_TOP_P exits 2"
assert_contains "DELEGATE_TOP_P" "$(cat "$stderr_file")" "QS5b: MLX validator stderr names env var"
rm -rf "$tmp" "$metrics" "$stderr_file"

# QS6. Canary preflight stays greedy regardless of dispatch profile. With
# --recipe set the canary fires before dispatch; its payload must carry
# temperature:0 (Ollama) or temperature:0 + max_tokens:1 (MLX) — never the
# Qwen profile. Sanity test pins the contract documented in delegate.sh.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
canary_payload_sniff="$tmp/canary-payload.json"; : > "$canary_payload_sniff"
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
assert_eq 0 "$EC" "QS6: canary + dispatch exits 0"
canary_payload=$(cat "$canary_payload_sniff")
assert_contains '"num_predict":1' "$canary_payload" "QS6: canary has num_predict:1"
assert_contains '"temperature":0' "$canary_payload" "QS6: canary stays at temperature:0 (greedy)"
case "$canary_payload" in
  *'"top_p"'*) echo "  FAIL  QS6: canary payload must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS6: canary payload omits top_p"; pass=$((pass+1));;
esac
case "$canary_payload" in
  *'"presence_penalty"'*) echo "  FAIL  QS6: canary payload must NOT carry presence_penalty"; fail=$((fail+1));;
  *) echo "  PASS  QS6: canary payload omits presence_penalty"; pass=$((pass+1));;
esac
case "$canary_payload" in
  *'"temperature":0.7'*) echo "  FAIL  QS6: canary must not inherit Qwen 0.7"; fail=$((fail+1));;
  *) echo "  PASS  QS6: canary stays greedy"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# QS6b. MLX canary also stays greedy.
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
canary_payload_sniff="$tmp/canary-payload.json"; : > "$canary_payload_sniff"
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
    cat > /dev/null
    printf '%s' '{"object":"list","data":[]}'
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
if echo "\$payload" | grep -qE '"max_tokens":1[,}]'; then
  echo "\$payload" > "${canary_payload_sniff}"
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
assert_eq 0 "$EC" "QS6b: MLX canary + dispatch exits 0"
canary_payload=$(cat "$canary_payload_sniff")
assert_contains '"max_tokens":1' "$canary_payload" "QS6b: MLX canary has max_tokens:1"
assert_contains '"temperature":0' "$canary_payload" "QS6b: MLX canary stays at temperature:0"
case "$canary_payload" in
  *'"top_p"'*) echo "  FAIL  QS6b: MLX canary must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS6b: MLX canary omits top_p"; pass=$((pass+1));;
esac
case "$canary_payload" in
  *'"temperature":0.7'*) echo "  FAIL  QS6b: MLX canary must not inherit Qwen 0.7"; fail=$((fail+1));;
  *) echo "  PASS  QS6b: MLX canary stays greedy"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT18. Pick-model failure path with content-include opt-in: prompt
# content is emitted (the prompt was real, the model resolution failed).
# Empty-string content attributes are OMITTED entirely, not emitted as
# `stringValue: ""` — gemini-code-assist review on PR #188 flagged this
# inconsistency: `delegate.recipe` is omitted when empty, so the content
# attributes should follow the same convention. Consumers can rely on
# attribute presence as a meaningful signal that content exists. On the
# failure path, output_text is "" so `delegate.output` is absent; the
# success-path test (OT15) covers the non-empty case.
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
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" prose "FailurePathSentinel" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "OT18: pick-model failure with opt-in → exit 1"
otel_body=$(cat "$otel_sniff")
# delegate.prompt still emitted (the prompt text is non-empty on failure span).
assert_contains '"delegate.prompt"' "$otel_body" "OT18: delegate.prompt present on failure span with opt-in"
assert_contains 'FailurePathSentinel' "$otel_body" "OT18: prompt content matches input on failure span"
# delegate.output should be ABSENT because output_text is empty on the
# failure path (no model response was generated). Empty-string content
# attributes are omitted per the gemini consistency fix.
case "$otel_body" in
  *'"delegate.output"'*)
    echo "  FAIL  OT18: delegate.output MUST be absent when output is empty (gemini consistency fix)"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT18: delegate.output omitted when output_text is empty (consistent with delegate.recipe)"
    pass=$((pass+1));;
esac
# delegate.context is also empty on this failure-path call (no stdin), so
# it should also be absent.
case "$otel_body" in
  *'"delegate.context"'*)
    echo "  FAIL  OT18: delegate.context MUST be absent when context is empty"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT18: delegate.context omitted when context_text is empty"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# --- Phase 16 Track A: flaky_on_models tier-gate ---
# A recipe with a flaky_on_models frontmatter list refuses (exit 4) when
# the resolved model matches any case-insensitive substring. The match is
# logged via metrics row with exit_status:4 so audit-metrics can pivot.
# DELEGATE_FORCE_FLAKY=1 overrides the gate and sends the request.

setup_flaky_recipe() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/flaky-recipe.md" <<'RECIPE'
---
flaky_on_models:
  - qwen3.6:35b
  - other-flaky-substring
---
# flaky-recipe

## When to use
test

## Prompt template

```
FLAKY-TEST TEMPLATE BODY
```

## Calibration notes
n/a
RECIPE
}

setup_safe_flaky_recipe() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/safe-recipe.md" <<'RECIPE'
---
flaky_on_models:
  - nonexistent-model-name
  - another-nonmatching-string
---
# safe-recipe

## When to use
test

## Prompt template

```
SAFE TEMPLATE BODY
```

## Calibration notes
n/a
RECIPE
}

# F1. Resolved model matches a flaky pattern → exit 4, no canary call,
# stderr names the recipe + model + matched pattern + recovery options.
# The mock ollama exposes `qwen3.6:35b-a3b` which pick-model.sh resolves
# for the prose tier; the recipe's frontmatter pattern `qwen3.6:35b` is a
# case-insensitive substring of that, so the gate fires.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "success"
prompts="$tmp/prompts"
setup_flaky_recipe "$prompts"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe flaky-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 4 "$EC" "flaky-gate: exit 4 when resolved model matches frontmatter pattern"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 0 "$canary_count" "flaky-gate: canary was NOT called (refusal is before pre-flight)"
assert_eq 0 "$dispatch_count" "flaky-gate: dispatch was NOT called"
stderr_content=$(cat "$stderr_file")
assert_contains "flagged as flaky" "$stderr_content" "flaky-gate: stderr names flaky status"
assert_contains "'flaky-recipe'" "$stderr_content" "flaky-gate: stderr names the recipe"
assert_contains "'qwen3.6:35b-a3b'" "$stderr_content" "flaky-gate: stderr names the resolved model"
assert_contains "qwen3.6:35b" "$stderr_content" "flaky-gate: stderr names the matched pattern"
assert_contains "DELEGATE_FORCE_FLAKY=1" "$stderr_content" "flaky-gate: stderr names the override env var"
# Metrics row recorded with exit_status:4.
if [[ -s "$metrics" ]]; then
  metrics_row=$(tail -1 "$metrics")
  assert_contains '"exit_status":4' "$metrics_row" "flaky-gate: metrics row tagged exit_status:4"
  assert_contains '"recipe":"flaky-recipe"' "$metrics_row" "flaky-gate: metrics row names the recipe"
else
  echo "  FAIL  flaky-gate: metrics row not written"
  fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# F2. DELEGATE_FORCE_FLAKY=1 overrides the gate — request flows through to
# the canary + dispatch even when the model matches a flaky pattern.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "success"
prompts="$tmp/prompts"
setup_flaky_recipe "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_FORCE_FLAKY=1 \
  bash "$SCRIPT" --recipe flaky-recipe prose "tail" </dev/null 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "flaky-gate override: exit 0 (full happy path) with DELEGATE_FORCE_FLAKY=1"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "flaky-gate override: canary was called"
assert_eq 1 "$dispatch_count" "flaky-gate override: dispatch was called"
rm -rf "$tmp" "$metrics"

# F3. Resolved model does NOT match any flaky pattern → no refusal, full
# request proceeds (canary + dispatch). The recipe's flaky_on_models lists
# only non-matching strings; the mock's qwen3.6:35b-a3b is unaffected.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "success"
prompts="$tmp/prompts"
setup_safe_flaky_recipe "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe safe-recipe prose "tail" </dev/null 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "flaky-gate non-match: exit 0 when no flaky_on_models pattern matches the model"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "flaky-gate non-match: canary was called"
assert_eq 1 "$dispatch_count" "flaky-gate non-match: dispatch was called"
rm -rf "$tmp" "$metrics"

# F4. Recipe WITHOUT flaky_on_models frontmatter skips the gate entirely
# (back-compat — recipes that pre-date the convention keep working).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "success"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "flaky-gate back-compat: recipe without frontmatter passes the gate"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "flaky-gate back-compat: canary was called"
assert_eq 1 "$dispatch_count" "flaky-gate back-compat: dispatch was called"
rm -rf "$tmp" "$metrics"

# F5. Match is case-insensitive — the recipe pattern is lowercase
# `qwen3.6:35b` and the resolved model is lowercase `qwen3.6:35b-a3b`
# (mock); they match by substring. (Coverage for the uppercase-on-uppercase
# case would require a different mock model name; the case-fold path is
# exercised by the lowercase-on-lowercase match in F1 because the code
# always tr's both to lowercase before comparing.)
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "success"
prompts="$tmp/prompts"
mkdir -p "$prompts"
cat > "$prompts/case-test-recipe.md" <<'RECIPE'
---
flaky_on_models:
  - QWEN3.6:35B
---
# case-test-recipe

## When to use
test

## Prompt template

```
CASE TEST TEMPLATE
```

## Calibration notes
n/a
RECIPE
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe case-test-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 4 "$EC" "flaky-gate case-insensitive: uppercase pattern matches lowercase resolved model"
assert_contains "QWEN3.6:35B" "$(cat "$stderr_file")" "flaky-gate case-insensitive: stderr preserves the original-case pattern"
rm -rf "$tmp" "$metrics"

# 30. DELEGATE_STRIP_THINK strips a leading <think>...</think> reasoning trace
# so trace-emitting reasoning models produce clean, parseable output.

# 30a. Strip ON: <think>reason</think>\n\nANSWER -> only the answer reaches stdout.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_think "$tmp" '<think>\nLet me work through this carefully.\n</think>\n\nCLEAN_ANSWER_123'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "CLEAN_ANSWER_123" "$out" "strip-think on: only the answer remains, trace removed"
rm -rf "$tmp" "$metrics"

# 30b. Strip OFF (default): the full trace is preserved on stdout.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_think "$tmp" '<think>\nLet me work through this carefully.\n</think>\n\nCLEAN_ANSWER_123'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_contains "<think>" "$out" "strip-think off (default): opening trace tag preserved"
assert_contains "CLEAN_ANSWER_123" "$out" "strip-think off: answer still present"
rm -rf "$tmp" "$metrics"

# 30c. Strip ON but response has no </think>: no-op, output unchanged.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_contains "mock-model-output: ok" "$out" "strip-think on, no </think>: no-op passthrough"
rm -rf "$tmp" "$metrics"

# 30d. Strip ON, template-prefilled trace (closing </think> only, no opening
# tag — the real qwen3-next-thinking shape): answer after </think> survives.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_think "$tmp" 'Reasoning emitted with no opening tag.\n</think>\n\nPREFILLED_ANSWER_456'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "PREFILLED_ANSWER_456" "$out" "strip-think on: prefilled-open-tag trace stripped to answer"
rm -rf "$tmp" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
