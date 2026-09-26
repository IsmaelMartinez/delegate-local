#!/usr/bin/env bash
# Unit tests for scripts/delegate.sh. Mocks `curl` on a restricted PATH so the
# run is the same on a machine with a live model server.

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
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpectedly found '$needle')"; fail=$((fail+1)); fi
}

# Every mock curl answers GET {base}/models from this list: a mock that only
# knew the dispatch call would fail to resolve a tier, or hang because the
# discovery request carries no stdin. Tests set MOCK_MODELS before building a
# mock and restore it afterwards.
MOCK_MODELS='qwen3.6:35b-a3b'
mock_models_json() {
  local out="" id
  for id in "$@"; do
    [[ -n "$out" ]] && out="$out,"
    out="$out{\"id\":\"${id//\"/\\\"}\",\"object\":\"model\"}"
  done
  printf '{"object":"list","data":[%s]}' "$out"
}


make_mock_curl_models_only() {
  # Serves GET {base}/models and refuses everything else. For tests where
  # resolution is expected to fail: without a curl mock at all, the real curl
  # on SAFE_PATH would reach a live daemon and resolve a real model.
  local dir="$1"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in */models) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;; esac
done
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

make_mock_curl_ok() {
  # Drains stdin, copies the JSON payload to a sniff file if asked, answers
  # discovery with $MOCK_MODELS, and honours the -o body_file / -w
  # "%{time_starttransfer}" pair delegate.sh uses for TTFB (a synthetic 0.001s
  # becomes queue_wait_ms=1).
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
if (( saw_probe == 1 )); then printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0; fi
cat > "${sniff}"
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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
  # Exits non-zero before writing a body or a TTFB, as a refused connection
  # does; delegate.sh must then default queue_wait_ms to 0.
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
# Discovery: pick-model.sh probes GET {base}/models before any dispatch, and
# that request has no stdin, so this arm answers and exits before anything
# reads stdin.
for _a in "$@"; do
  case "$_a" in */models) printf '%s' '{"object":"list","data":[{"id":"qwen3.6:35b-a3b"}]}'; exit 0 ;; esac
done
cat > /dev/null
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

make_mock_curl_think() {
  # Like make_mock_curl_ok but the content is $2, a JSON-escaped string (use
  # \n for newlines), for the <think> stripping tests.
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
if (( saw_probe == 1 )); then printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0; fi
cat > /dev/null
body='{"choices":[{"message":{"content":"${resp}"},"finish_reason":"stop"}]}'
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

make_mock_curl_argv() {
  # Records its own argv to $2 as one space-joined line (so a test can assert
  # "--max-time 600" as a unit), then behaves like make_mock_curl_ok.
  local dir="$1" argv_file="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${argv_file}"
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
if (( saw_probe == 1 )); then printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0; fi
cat > /dev/null
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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
  assert_contains '"enable_thinking":false' "$payload" "payload: enable_thinking:false default"
  assert_contains '"stream":false' "$payload" "payload: stream:false"
  # A bare call is greedy for every model: temperature:0 and no
  # top_p/top_k/presence_penalty; env vars opt in to sampling.
  assert_contains '"temperature":0' "$payload" "payload: bare greedy temperature:0"
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
# A bare call writes no sampling_* keys to the row.
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

# 4. pick-model failure (no matching model served) is reflected in metrics +
# exit. The mock serves a model no tier prefers rather than nothing: without a
# mock, the real curl would reach a live daemon and resolve a real model.
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
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
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=true \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true: exits 0"
assert_contains '"enable_thinking":true' "$(cat "$sniff")" "payload: enable_thinking:true when overridden"
rm -rf "$tmp" "$metrics"

# 6b. DELEGATE_THINK with a non-boolean stray value is normalised to false
# (so a jq parse error can't kill the delegation).
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=yes \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=yes (non-boolean): still exits 0"
assert_contains '"enable_thinking":false' "$(cat "$sniff")" "payload: non-boolean DELEGATE_THINK normalises to false"
rm -rf "$tmp" "$metrics"

# 7. HTTP failure (curl non-zero) propagates and is logged.
tmp=$(mktemp -d)
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

# 8. --recipe NAME prepends the '## Prompt template' fenced block of
# prompts/NAME.md, substitutes --var values into {{key}}, and tags the row.
tmp=$(mktemp -d)
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

# 13a. `&` in a --var value or the piped context is literal (#547). bash 5.2
# turns on patsub_replacement, where `&` in a ${t//pat/rep} replacement means
# the matched text, so `R&D` rendered as `R{{lead}}D`. macOS bash 3.2 has no
# such option, so on it this passes with or without the fix.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/amp.md" <<'EOF'
# amp

## When to use
Test.

## Prompt template

```
LEAD: {{lead}}
CTX: {{stdin}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(printf '%s' 'x&y && z\&w' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe amp --var 'lead=R&D && a\&b' prose "tail" 2>&1) || EC=$?
assert_eq 0 "$EC" "--var with '&': exits 0"
rendered=$(jq -r '.messages[0].content' "$sniff" 2>/dev/null)
expected='LEAD: R&D && a\&b
CTX: x&y && z\&w

tail'
assert_eq "$expected" "$rendered" "--var and stdin with '&': rendered literally"
rm -rf "$tmp" "$metrics"

# 14. --var without '=' is rejected.
tmp=$(mktemp -d)
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

# 14a. --var key with glob metacharacters is rejected: the key goes into a
# bash pattern replacement, where it would match wider than the literal {{key}}.
tmp=$(mktemp -d)
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
  bash "$SCRIPT" --recipe x --var 'a*b=x' prose "p" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--var with glob-metachar key -> exit 2"
assert_contains "invalid key 'a*b'" "$out" "--var: error names the bad key"
rm -rf "$tmp" "$metrics"

# 14b. --var key that is a plain identifier (letters, digits, underscore)
# still substitutes normally after the key-shape guard.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/ident.md" <<'EOF'
# ident

## When to use
t

## Prompt template

```
hello {{a_b1}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe ident --var a_b1=ok prose "p" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--var with identifier key (underscore + digit): exits 0"
assert_contains 'hello ok' "$(cat "$sniff")" "--var: identifier key substituted into payload"
rm -rf "$tmp" "$metrics"

# 15. A --var value containing {{...}} must not trip the unsubstituted-
# placeholder guard, which checks the template's placeholders, not the result.
tmp=$(mktemp -d)
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

# 16. A markdown heading inside the fenced block must not end the section.
tmp=$(mktemp -d)
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

# 17. prompt_chars includes the recipe template length.
tmp=$(mktemp -d)
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
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe sized prose "go" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe metric: exits 0"
line=$(cat "$metrics")
# 10 (template, trailing newline stripped by command substitution) + 2 ("go").
assert_contains '"prompt_chars":12' "$line" "--recipe metric: prompt_chars includes template length"
rm -rf "$tmp" "$metrics"

# 12. MLX: dispatches to /v1/chat/completions, parses
# .choices[0].message.content, and tags the metrics line with backend:"mlx".
make_mock_curl_mlx_ok() {
  # Answers discovery and dispatch in the chat-completions shape. The argv
  # sniff holds the last invocation, which is always the dispatch.
  local dir="$1" payload_sniff="${2:-/dev/null}" argv_sniff="${3:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"/v1/models"*)
      # Probe: drain stdin, emit a minimal models-list response, exit 0.
      cat > /dev/null
      printf '%s' '$(mock_models_json $MOCK_MODELS)'
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

# 12a. Happy path with the MLX backend.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
argv_sniff="$tmp/argv.txt"
MOCK_MODELS='mlx-community/Qwen3.6-35B-A3B-Instruct-4bit'
make_mock_curl_mlx_ok "$tmp" "$payload_sniff" "$argv_sniff"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX happy path exits 0"
assert_contains "mlx-output-ok" "$out" "MLX output parsed from .choices[0].message.content"
line=$(cat "$metrics")
assert_contains '"backend":"mlx"' "$line" "MLX metrics: backend field"
assert_contains '"model":"mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"' "$line" "MLX metrics: model field"
assert_contains '"tier":"prose"' "$line" "MLX metrics: tier field"
# Raw /v1/completions bypasses the chat template and returns whitespace on
# instruction-tuned models.
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
# enable_thinking:false mirrors Ollama's think:false so the answer lands in
# .content rather than .reasoning.
payload=$(cat "$payload_sniff")
assert_contains '"model":"mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"' "$payload" "MLX payload: model field"
assert_contains '"max_tokens":' "$payload" "MLX payload: max_tokens (OpenAI shape)"
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

# 12d. MLX_HOST override is honoured by the dispatch URL.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "/dev/null" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  MLX_HOST="http://10.0.0.5:9999" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX_HOST override: exits 0"
assert_contains "http://10.0.0.5:9999/v1/chat/completions" "$(cat "$argv_sniff")" "MLX_HOST override applied to curl URL"
rm -rf "$tmp" "$metrics"

# 12e. DELEGATE_MAX_TOKENS overrides the MLX max_tokens default.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_MAX_TOKENS=16384 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_MAX_TOKENS override: exits 0"
assert_contains '"max_tokens":16384' "$(cat "$payload_sniff")" "DELEGATE_MAX_TOKENS override flows into payload"
rm -rf "$tmp" "$metrics"

# 12e1. A non-numeric DELEGATE_MAX_TOKENS is refused up front (#547): `4k`
# used to make jq --argjson fail and curl post an empty body.
tmp=$(mktemp -d)
make_mock_curl_mlx_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_MAX_TOKENS=4k \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "DELEGATE_MAX_TOKENS=4k: exits 2"
assert_contains "DELEGATE_MAX_TOKENS='4k' is not a positive integer" "$out" "DELEGATE_MAX_TOKENS=4k: validation message"
rm -rf "$tmp" "$metrics"

# 12e1a. Numeric but not a positive JSON integer: strict providers reject
# 4.0 and -1, and 04 is not valid JSON, so jq --argjson fails on it.
for bad_mt in 4.0 -1 04; do
  tmp=$(mktemp -d)
  make_mock_curl_mlx_ok "$tmp"
  metrics=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_MAX_TOKENS="$bad_mt" \
    DELEGATE_METRICS_FILE="$metrics" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
  assert_eq 2 "$EC" "DELEGATE_MAX_TOKENS=$bad_mt: exits 2"
  assert_contains "DELEGATE_MAX_TOKENS='$bad_mt' is not a positive integer" "$out" "DELEGATE_MAX_TOKENS=$bad_mt: validation message"
  rm -rf "$tmp" "$metrics"
done

# 12e2. A context above ARG_MAX (1 MiB on macOS, 128 KiB per argument on
# Linux) reaches the provider intact, posted as JSON rather than the
# form-urlencoded type `curl -d` sends (#547).
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff" "$argv_sniff"
metrics=$(mktemp)
big_ctx="$tmp/big.txt"
head -c 1153434 /dev/zero | tr '\0' 'a' > "$big_ctx"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" <"$big_ctx" 2>&1) || EC=$?
assert_eq 0 "$EC" "1.1 MB context: exits 0"
# context + blank-line join + the 9-char prompt.
got_bytes=$(jq -j '.messages[0].content' "$payload_sniff" 2>/dev/null | wc -c | tr -d ' ')
assert_eq 1153445 "$got_bytes" "1.1 MB context: payload content byte count intact"
argv=$(cat "$argv_sniff")
assert_contains "Content-Type: application/json" "$argv" "dispatch: JSON content type header"
assert_contains "--data-binary @-" "$argv" "dispatch: body posted with --data-binary"
assert_not_contains " -d @-" "$argv" "dispatch: no form-urlencoded -d"
rm -rf "$tmp" "$metrics"

# 12e3. An empty payload is refused before dispatch with its own message and
# a failure row, never posted as a 0-byte body that reads as a daemon problem.
# A jq shim fails only on the chat-payload build.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "/dev/null" "$argv_sniff"
real_jq=$(PATH="$SAFE_PATH" command -v jq)
cat > "$tmp/jq" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in *'max_tokens:\$mt'*) exit 5 ;; esac
done
exec "$real_jq" "\$@"
EOF
chmod +x "$tmp/jq"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 101 "$EC" "empty payload: exits 101"
assert_contains "request payload is empty" "$out" "empty payload: names the cause"
assert_not_contains "check the provider daemon" "$out" "empty payload: no daemon hint"
assert_eq "" "$(cat "$argv_sniff" 2>/dev/null)" "empty payload: nothing dispatched"
assert_contains '"exit_status":101' "$(cat "$metrics")" "empty payload: failure row written"
rm -rf "$tmp" "$metrics"

# 12f. DELEGATE_THINK=true on MLX flips chat_template_kwargs.enable_thinking.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_THINK=true \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true on MLX: exits 0"
assert_contains '"enable_thinking":true' "$(cat "$payload_sniff")" "DELEGATE_THINK=true flips enable_thinking on for MLX"
rm -rf "$tmp" "$metrics"

# 13. A model name with an embedded double quote still yields valid JSON:
# pick-model returns whatever a provider reports.
tmp=$(mktemp -d)
MOCK_MODELS='qwen3.6:35b"weird-name'
make_mock_curl_ok "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "jq-metrics: weird model name still exits 0"
line=$(cat "$metrics")
if echo "$line" | jq -e . >/dev/null 2>&1; then
  echo "  PASS  jq-metrics: line is valid JSON despite embedded quote in model"
  pass=$((pass+1))
else
  echo "  FAIL  jq-metrics: produced invalid JSON for weird model name"
  echo "        line: $line"
  fail=$((fail+1))
fi
decoded_model=$(echo "$line" | jq -r '.model')
assert_eq 'qwen3.6:35b"weird-name' "$decoded_model" "jq-metrics: model field decodes to original string"
rm -rf "$tmp" "$metrics"

# 14. Verdict nudge prints to stderr on a successful call.
tmp=$(mktemp -d)
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
# The nudge is the only place most callers read the verdict contract, so it
# names all three verdicts and --final.
assert_contains "scaffold" "$stderr_content" "verdict-nudge: names the scaffold verdict"
assert_contains "--final" "$stderr_content" "verdict-nudge: names --final so the pair gets captured"
assert_contains "delegate-feedback.sh --source agent --id " "$stderr_content" "verdict-nudge: names --source agent and --id"
# Each verdict is its own complete command on its own line: `a | b | c` runs
# as a pipeline and `a, b or c` passes `hit,` as the verdict. The note after a
# command is a shell comment so a whole-line copy still runs.
nudge_cmds=$(printf '%s\n' "$stderr_content" | grep -F 'delegate-feedback.sh')
assert_eq 3 "$(printf '%s\n' "$nudge_cmds" | grep -c '')" "verdict-nudge: three verdict commands, one per line"
nudge_re='bash scripts/delegate-feedback\.sh --source agent --id [0-9a-f]{16} (scaffold "<reason>"|miss "<reason>"|hit)( +# [a-z -]+)?$'
assert_eq 3 "$(printf '%s\n' "$nudge_cmds" | grep -Ec "$nudge_re")" "verdict-nudge: every line is one complete command plus an optional # note"
assert_eq 1 "$(printf '%s\n' "$nudge_cmds" | grep -Ec -- '--id [0-9a-f]{16} hit( |$)')" "verdict-nudge: a hit command"
assert_eq 1 "$(printf '%s\n' "$nudge_cmds" | grep -Ec -- '--id [0-9a-f]{16} scaffold "<reason>"')" "verdict-nudge: a scaffold command"
assert_eq 1 "$(printf '%s\n' "$nudge_cmds" | grep -Ec -- '--id [0-9a-f]{16} miss "<reason>"')" "verdict-nudge: a miss command"
case "$nudge_cmds" in
  *","*|*" | "*|*" or "*) echo "  FAIL  verdict-nudge: no command line joins alternatives with ',', '|' or 'or'"; fail=$((fail+1));;
  *) echo "  PASS  verdict-nudge: no command line joins alternatives with ',', '|' or 'or'"; pass=$((pass+1));;
esac
# One tier (ADR 0030): there is no human taste judgment to drop the flag for.
case "$stderr_content" in
  *"drop --source"*|*"taste judgment"*) echo "  FAIL  verdict-nudge: no human-tier hand-off"; fail=$((fail+1));;
  *) echo "  PASS  verdict-nudge: no human-tier hand-off"; pass=$((pass+1));;
esac
# stdout holds only the model output so downstream pipes keep working.
if echo "$out" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge: leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge: stdout unaffected"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 14a. A non-TTY caller still gets the nudge (#149): a `[[ -t 2 ]]` gate would
# silence it for Agent SDK tool calls, routines and `2>logfile` redirects.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(echo "some context" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge non-TTY: exits 0 with piped stdin and redirected stderr"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate: record verdict" "$stderr_content" "verdict-nudge non-TTY: nudge still printed when neither stdin nor stderr is a TTY"
# Also with stdout explicitly piped.
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
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge opt-out: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 16. NO_METRICS=1 also silences the nudge: there is no row to verdict.
tmp=$(mktemp -d)
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

# 17. A non-zero exit also silences the nudge: there is no output to judge.
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
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

# 17a. DELEGATE_LOCAL_VERDICT_NUDGE_FD=N redirects the nudge to fd N, for
# callers that capture 2>&1 and want stderr clean (#139).

# 17a-1. fd 3 redirected to a file: nudge lands there, not on fd 2.
tmp=$(mktemp -d)
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
if echo "$out" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge FD=3: nudge leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3: stdout unaffected"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file" "$nudge_file"

# 17a-2. fd 3 set but not redirected: the call still succeeds and the failed
# write is absorbed, so no "Bad file descriptor" lands on the fd 2 the caller
# wanted clean.
tmp=$(mktemp -d)
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
if echo "$stderr_content" | grep -qi "bad file descriptor"; then
  echo "  FAIL  verdict-nudge FD=3 no redirect: 'Bad file descriptor' leaked back to fd 2"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=3 no redirect: failed write absorbed silently"; pass=$((pass+1))
fi
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge FD=3 no redirect: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-3. An explicit FD=2 behaves like unset.
tmp=$(mktemp -d)
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

# 17a-4. FD=1 is allowed: the nudge lands inline on stdout.
tmp=$(mktemp -d)
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

# 17a-5. FD=0 is rejected with exit 2 before the model is contacted.
tmp=$(mktemp -d)
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
if [[ -s "$metrics" ]]; then
  echo "  FAIL  verdict-nudge FD=0: metrics row written despite pre-flight rejection"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge FD=0: no metrics row (rejection fires pre-flight)"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 17a-6. FD=foo (non-numeric) is rejected. exit 2.
tmp=$(mktemp -d)
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

# 17a-7. FD=-1 (negative) is rejected.
tmp=$(mktemp -d)
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

# 17a-7b. FD=10 (multi-digit) is rejected: bash 3.2 has no reliable `>&$N`
# for N>=10, so the validation fails loud rather than the write failing silently.
tmp=$(mktemp -d)
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

# 17a-7c. FD=99 is also rejected.
tmp=$(mktemp -d)
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

# 17a-8. FD set and NO_VERDICT_NUDGE=1: suppression beats redirect.
tmp=$(mktemp -d)
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

# 17a-9. FD set and NO_METRICS=1: no row, so no nudge.
tmp=$(mktemp -d)
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

# 17a-10. FD set on a non-zero exit: no nudge.
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
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

# 18. Pre-flight canary on --recipe (#110): a 1-token probe fails loud before
# the input investment is sunk. The mock tells the canary from the dispatch by
# its `"num_predict":1` / `"max_tokens":1` signature, behaves per $4 on the
# canary, and logs `canary` or `dispatch` per invocation so tests can count.
make_mock_curl_probe_aware() {
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
  *"/v1/models"*) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;;
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
    *)          printf '%s' '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}'; exit 0 ;;
  esac
fi
echo "dispatch url=\$url" >> "${invocations_log}"
echo "\$payload" > "${sniff}"
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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
assert_contains 'CANARY-TEST TEMPLATE BODY' "$(cat "$sniff")" "canary success: dispatch carries recipe template"
# The canary writes no row on success.
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "canary success: one metrics row"
assert_contains '"exit_status":0' "$(cat "$metrics")" "canary success: dispatch logged status:0"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18b. Canary times out (curl --max-time fires, exit 28) → exit 3, no
# dispatch, stderr names the recipe + model + recovery options.
tmp=$(mktemp -d)
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
if [[ -s "$sniff" ]]; then
  echo "  FAIL  canary timeout: dispatch sniff should be empty"; fail=$((fail+1))
else
  echo "  PASS  canary timeout: dispatch sniff stays empty"; pass=$((pass+1))
fi
stderr_content=$(cat "$stderr_file")
assert_contains "pre-flight canary" "$stderr_content" "canary timeout: stderr names the canary"
# The message names the cause for this curl exit, not "timeout" for every failure.
assert_contains "did not return within 10s" "$stderr_content" "canary timeout: stderr names the timeout duration"
assert_contains "curl --max-time fired" "$stderr_content" "canary timeout: stderr names the curl flag that fired"
assert_contains "recipe='canary-recipe'" "$stderr_content" "canary timeout: stderr names recipe"
assert_contains "model='qwen3.6:35b-a3b'" "$stderr_content" "canary timeout: stderr names resolved model"
assert_contains "DELEGATE_PREFLIGHT_TIMEOUT" "$stderr_content" "canary timeout: stderr suggests timeout override"
assert_contains "DELEGATE_NO_PREFLIGHT=1" "$stderr_content" "canary timeout: stderr names the opt-out"
assert_contains "hand-write" "$stderr_content" "canary timeout: stderr suggests hand-writing"
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "canary timeout: one metrics row"
metric_line=$(cat "$metrics")
assert_contains '"exit_status":3' "$metric_line" "canary timeout: metrics row tagged status:3"
assert_contains '"recipe":"canary-recipe"' "$metric_line" "canary timeout: metrics row carries recipe name"
assert_contains '"model":"qwen3.6:35b-a3b"' "$metric_line" "canary timeout: metrics row carries resolved model"
# A failed recipe row still names the template that was live.
. "$REPO/scripts/lib/recipe.sh"
assert_contains "\"template_sha\":\"$(recipe_template_sha "$prompts/canary-recipe.md")\"" "$metric_line" \
  "canary timeout: metrics row carries template_sha"
# Verdict nudge must NOT fire on a status:3 exit.
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  canary timeout: verdict nudge leaked"; fail=$((fail+1))
else
  echo "  PASS  canary timeout: verdict nudge silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18c. DELEGATE_NO_PREFLIGHT=1 skips the canary; the dispatch still runs.
tmp=$(mktemp -d)
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

# 18e. DELEGATE_PREFLIGHT_TIMEOUT=N flows into the canary's --max-time.
tmp=$(mktemp -d)
# Records the canary's argv only.
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
  *"/v1/models"*) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;;
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
  printf '%s' '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}'
  exit 0
fi
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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

# 18f. No --recipe: the canary is skipped.
tmp=$(mktemp -d)
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

# 18g. MLX canary uses /v1/chat/completions with max_tokens:1; the mock
# sniffs the canary payload separately from the dispatch.
tmp=$(mktemp -d)
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
    cat > /dev/null
    printf '%s' '$(mock_models_json $MOCK_MODELS)'
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

# 18i. Canary connection refused (curl exit 7): exit 3 and stderr names that
# cause rather than the timeout copy.
tmp=$(mktemp -d)
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

# 18j. Canary HTTP error (curl exit 22): exit 3 and stderr names that cause.
tmp=$(mktemp -d)
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

# 19. The delegate-meta stderr line is the contract surface SKILL.md teaches
# the assistant to read.
tmp=$(mktemp -d)
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
# String fields are quoted so values with spaces stay one token; integers stay bare.
assert_contains 'model="qwen3.6:35b-a3b' "$stderr_content" "delegate-meta: model field (quoted)"
assert_contains 'tier="prose"' "$stderr_content" "delegate-meta: tier field (quoted)"
assert_contains 'backend="mlx"' "$stderr_content" "delegate-meta: backend field (quoted)"
assert_contains "tokens_local=" "$stderr_content" "delegate-meta: tokens_local field (bare integer)"
assert_contains "duration_ms=" "$stderr_content" "delegate-meta: duration_ms field (bare integer)"
if echo "$out" | grep -q "delegate-meta:"; then
  echo "  FAIL  delegate-meta: leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta: stdout unaffected"; pass=$((pass+1))
fi
# tokens_local is (prompt + context + output chars) / 4, compared numerically.
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

# 19a. The meta line names the row it wrote so the nudge can hand the pin
# back (#474). The value must be the row's ts byte for byte: a reformatted
# or re-read clock matches no row.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>"$stderr_file"
row_ts=$(jq -r '.ts' "$metrics")
if [[ "$row_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "  PASS  delegate-meta ts: the metrics row carries an ISO 8601 ts ($row_ts)"; pass=$((pass+1))
else
  echo "  FAIL  delegate-meta ts: metrics row ts missing or malformed ('$row_ts')"; fail=$((fail+1))
fi
meta_ts=$(grep '^delegate-meta:' "$stderr_file" | grep -oE 'ts="[^"]*"' | cut -d'"' -f2)
assert_eq "$row_ts" "$meta_ts" "delegate-meta ts: ts field is the metrics row's ts, byte for byte"
# ts is second-precision and parallel delegations share it, so the pin is the
# row's otel_span_id (16 hex, generated on every row).
row_id=$(jq -r '.otel_span_id' "$metrics")
if [[ "$row_id" =~ ^[0-9a-f]{16}$ ]]; then
  echo "  PASS  delegate-meta id: the metrics row carries a 16-hex otel_span_id ($row_id)"; pass=$((pass+1))
else
  echo "  FAIL  delegate-meta id: metrics row otel_span_id missing or malformed ('$row_id')"; fail=$((fail+1))
fi
meta_id=$(grep '^delegate-meta:' "$stderr_file" | grep -oE 'id="[^"]*"' | cut -d'"' -f2)
assert_eq "$row_id" "$meta_id" "delegate-meta id: id field is the metrics row's otel_span_id, byte for byte"
assert_contains "--id $row_id " "$(grep 'record verdict' "$stderr_file")" \
  "verdict-nudge: the copyable command already carries --id with the row's span id"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 19c. A row that could not be appended is not a row: the call still
# succeeds, but the meta line names no ts/id and nothing nudges for a verdict.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE=/dev/null/metrics.jsonl \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta unwritable: the delegation still succeeds"
assert_contains "mock-model-output" "$out" "delegate-meta unwritable: model output still on stdout"
meta_line=$(grep '^delegate-meta:' "$stderr_file")
assert_contains 'model="' "$meta_line" "delegate-meta unwritable: meta line still printed"
if [[ "$meta_line" == *' ts="'* || "$meta_line" == *' id="'* ]]; then
  echo "  FAIL  delegate-meta unwritable: names a row that was never appended"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta unwritable: no ts/id when the append failed"; pass=$((pass+1))
fi
if grep -q 'record verdict' "$stderr_file"; then
  echo "  FAIL  delegate-meta unwritable: nudges for a row that was never appended"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta unwritable: no verdict nudge when the append failed"; pass=$((pass+1))
fi
rm -rf "$tmp" "$stderr_file"

# 19d. The row carries CLAUDE_CODE_SESSION_ID so the hooks can scope a
# projectless lookup to the session (#476): present when set, absent when
# unset, never an empty string.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" CLAUDE_CODE_SESSION_ID="0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1
assert_eq "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b" "$(jq -r '.session // ""' "$metrics")" \
  "session: the row carries CLAUDE_CODE_SESSION_ID when it is set"
: > "$metrics"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1
assert_eq "false" "$(jq -r 'has("session")' "$metrics")" \
  "session: the field is absent when CLAUDE_CODE_SESSION_ID is unset"
: > "$metrics"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" CLAUDE_CODE_SESSION_ID= \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1
assert_eq "false" "$(jq -r 'has("session")' "$metrics")" \
  "session: an empty CLAUDE_CODE_SESSION_ID is treated as unset"
rm -rf "$tmp" "$metrics"

# 19b. With metrics off there is no row, so the meta line names no ts: a
# value that matches nothing would only send the caller to a --ts refusal.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
stderr_file=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>"$stderr_file"
meta_line=$(grep '^delegate-meta:' "$stderr_file")
assert_contains 'model="' "$meta_line" "delegate-meta ts: meta line still printed with metrics off"
if [[ "$meta_line" == *' ts="'* ]]; then
  echo "  FAIL  delegate-meta ts: names a ts although no row was written"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta ts: no ts field when no row was written"; pass=$((pass+1))
fi
rm -rf "$tmp" "$stderr_file"

# 20. DELEGATE_LOCAL_NO_META=1 silences the meta line only; the nudge and
# the metrics row are unaffected.
tmp=$(mktemp -d)
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
assert_contains "record verdict" "$stderr_content" "delegate-meta opt-out: verdict nudge unaffected"
assert_eq 1 "$(grep -c '^' "$metrics")" "delegate-meta opt-out: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 21. A non-zero exit silences the meta line.
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
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

# 22. --recipe NAME adds recipe=NAME to the meta line. The probe-aware mock
# with `ok` lets the canary pass so the dispatch emits the line.
tmp=$(mktemp -d)
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

# 23. Stdin probe (#169): `[[ ! -t 0 ]]` is true for an empty unix socket and
# `cat` then blocks forever; the probe is `-p /dev/stdin || -s /dev/stdin`.

# 23a. </dev/null: not a pipe, holds no data, so cat is skipped.
tmp=$(mktemp -d)
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

# 23b. Piped stdin still works, under the perl alarm to assert no hang.
tmp=$(mktemp -d)
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

# 23c. An empty AF_UNIX socket as stdin, the other end held open and never
# written: the alarm exits 142 if cat blocks.
tmp=$(mktemp -d)
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

# 24. Queue-wait / generation split (#170): queue_wait_ms + generation_ms ==
# duration_ms is the contract downstream consumers rely on.
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "queue-wait split: happy path exits 0"
line=$(cat "$metrics")
assert_contains '"queue_wait_ms":' "$line" "queue-wait split: queue_wait_ms field present"
assert_contains '"generation_ms":' "$line" "queue-wait split: generation_ms field present"
assert_contains '"duration_ms":' "$line" "queue-wait split: duration_ms field preserved"
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
sum=$((qwait_val + gen_val))
if [[ "$sum" == "$dur_val" ]]; then
  echo "  PASS  queue-wait split: queue_wait_ms + generation_ms == duration_ms ($qwait_val + $gen_val == $dur_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split: $qwait_val + $gen_val != $dur_val"
  fail=$((fail+1))
fi
# Exactly 1 proves the float-to-int path ran, not the empty-string-to-zero fallback.
assert_eq 1 "$qwait_val" "queue-wait split: synthetic 0.001s TTFB → 1 ms queue_wait_ms"
rm -rf "$tmp" "$metrics"

# 25. On a failed dispatch queue_wait_ms is 0 and generation_ms absorbs the
# whole duration, so the sum invariant still holds.
tmp=$(mktemp -d)
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
sum=$((qwait_val + gen_val))
if [[ "$sum" == "$dur_val" ]]; then
  echo "  PASS  queue-wait split on failure: sum-equals-duration invariant holds ($qwait_val + $gen_val == $dur_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split on failure: $qwait_val + $gen_val != $dur_val"
  fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# 26. A pick-model failure still emits both fields (queue_wait_ms = 0) so
# the row shape is the same on success and failure.
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "queue-wait split on pick-model failure: exit 1"
line=$(cat "$metrics")
assert_contains '"queue_wait_ms":' "$line" "queue-wait split on pick-model failure: queue_wait_ms still emitted"
assert_contains '"generation_ms":' "$line" "queue-wait split on pick-model failure: generation_ms still emitted"
assert_eq 0 "$(echo "$line" | jq -r '.queue_wait_ms')" "queue-wait split on pick-model failure: queue_wait_ms == 0"

# 27. Frontmatter `inputs:` (#161) declares key: integer|string with a `?`
# suffix for optional, validated before the model is contacted; recipes
# without the block keep their old behaviour.

# Writes a recipe with the given frontmatter and {{pr_number}}/{{body}} placeholders.
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
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
# The template references {{pr_number}} only, so the missing anchor cannot
# fail placeholder substitution.
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

# 27d2. An optional input with a placeholder in the body, --var provided:
# the value is substituted.
tmp=$(mktemp -d)
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

# 27d3. The same recipe with the optional --var omitted: the placeholder is
# blanked rather than tripping the unsubstituted-placeholder guard.
tmp=$(mktemp -d)
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

# 27e. No inputs: block: no type check runs.
tmp=$(mktemp -d)
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

# 27f. An undeclared --var passes through untouched.
tmp=$(mktemp -d)
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

# 27g. An optional `integer?` that is present is still type-checked.
tmp=$(mktemp -d)
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

# 27h. An unsupported type in inputs: is a recipe authoring error, exit 2.
tmp=$(mktemp -d)
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

# 27j. Piped stdin satisfies a declared `stdin: string` input.
tmp=$(mktemp -d)
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

# 23k. stdin: integer type-checks the piped value.
tmp=$(mktemp -d)
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

# 23l. The missing-required error has no trailing space.
tmp=$(mktemp -d)
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

# --- OTLP/HTTP exporter (#134): off by default, one span per call when
# DELEGATE_OTEL_ENDPOINT is set, failures never change the exit status,
# payload per docs/otel-schema.md ---

# Routes by URL: discovery, dispatch, or /v1/traces (body to $otel_sniff,
# exit per $otel_behaviour); logs `otel`/`dispatch` per invocation.
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
  *"/v1/models"*) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;;
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
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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

# OT1. DELEGATE_OTEL_ENDPOINT unset: no OTLP POST.
tmp=$(mktemp -d)
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
assert_eq 1 "$(grep -c '^' "$metrics")" "OT1: metrics row still written when exporter disabled"
rm -rf "$tmp" "$metrics"

# OT2. Endpoint set: exactly one OTLP POST, in the schema's shape.
tmp=$(mktemp -d)
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
otel_body=$(cat "$otel_sniff")
assert_contains '"resourceSpans"' "$otel_body" "OT2: body has resourceSpans envelope"
assert_contains '"scopeSpans"' "$otel_body" "OT2: body has scopeSpans"
assert_contains '"spans"' "$otel_body" "OT2: body has spans array"
assert_contains '"traceId":' "$otel_body" "OT2: body has traceId"
assert_contains '"spanId":' "$otel_body" "OT2: body has spanId"
if echo "$otel_body" | jq -e . >/dev/null 2>&1; then
  echo "  PASS  OT2: body parses as JSON"
  pass=$((pass+1))
else
  echo "  FAIL  OT2: body is not valid JSON"
  fail=$((fail+1))
fi
assert_contains '"gen_ai.operation.name"' "$otel_body" "OT2: gen_ai.operation.name"
assert_contains '"chat"' "$otel_body" "OT2: operation.name value is 'chat'"
assert_contains '"gen_ai.provider.name"' "$otel_body" "OT2: gen_ai.provider.name"
assert_contains '"mlx"' "$otel_body" "OT2: provider.name value is 'mlx'"
assert_contains '"gen_ai.request.model"' "$otel_body" "OT2: gen_ai.request.model"
assert_contains '"qwen3.6:35b-a3b"' "$otel_body" "OT2: request.model is the resolved model"
assert_contains '"gen_ai.request.temperature"' "$otel_body" "OT2: gen_ai.request.temperature"
assert_contains '"delegate.tier"' "$otel_body" "OT2: delegate.tier"
assert_contains '"prose"' "$otel_body" "OT2: delegate.tier value is 'prose'"
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT2: delegate.prompt_chars"
assert_contains '"delegate.context_chars"' "$otel_body" "OT2: delegate.context_chars"
assert_contains '"delegate.output_chars"' "$otel_body" "OT2: delegate.output_chars"
assert_contains '"delegate.queue_wait_ms"' "$otel_body" "OT2: delegate.queue_wait_ms"
assert_contains '"delegate.generation_ms"' "$otel_body" "OT2: delegate.generation_ms"
assert_contains '"delegate.estimated_tokens_avoided"' "$otel_body" "OT2: delegate.estimated_tokens_avoided"
assert_contains '"delegate.exit_status"' "$otel_body" "OT2: delegate.exit_status"
assert_contains '"kind":3' "$otel_body" "OT2: span kind=3 (CLIENT)"
assert_contains '"status":{"code":1}' "$otel_body" "OT2: span status OK on exit 0"
assert_contains '"service.name"' "$otel_body" "OT2: resource has service.name"
assert_contains '"delegate-local"' "$otel_body" "OT2: resource service.name value"
# The metrics row carries the same trace/span ids, which is the linkage.
metric_line=$(cat "$metrics")
assert_contains '"otel_trace_id":"' "$metric_line" "OT2: metrics row has otel_trace_id"
assert_contains '"otel_span_id":"' "$metric_line" "OT2: metrics row has otel_span_id"
trace_in_metrics=$(echo "$metric_line" | jq -r '.otel_trace_id')
trace_in_otel=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId')
assert_eq "$trace_in_metrics" "$trace_in_otel" "OT2: trace_id matches between metrics row and OTel body"
span_in_metrics=$(echo "$metric_line" | jq -r '.otel_span_id')
span_in_otel=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId')
assert_eq "$span_in_metrics" "$span_in_otel" "OT2: span_id matches between metrics row and OTel body"
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
# No-content rule (ADR 0007): no prompt or output text on the span.
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

# OT3. An OTel POST failure does not change the exit status, stdout or the row.
tmp=$(mktemp -d)
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
# Silent, not skipped.
otel_count=$(grep -c '^otel' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "OT3: OTel POST was attempted (one curl call to the endpoint)"
rm -rf "$tmp" "$metrics"

# OT4. An OTel timeout (curl exit 28) does not change the exit status either.
tmp=$(mktemp -d)
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

# OT5. DELEGATE_OTEL_TIMEOUT flows into the OTel curl's --max-time.
tmp=$(mktemp -d)
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

# OT6. DELEGATE_OTEL_HEADERS splits on comma into one -H per header.
tmp=$(mktemp -d)
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
auth_h=$(echo "$otel_args_line" | grep -o "\-H Authorization" | head -1)
tenant_h=$(echo "$otel_args_line" | grep -o "\-H X-Tenant" | head -1)
assert_eq "-H Authorization" "$auth_h" "OT6: -H prefix on Authorization header"
assert_eq "-H X-Tenant" "$tenant_h" "OT6: -H prefix on X-Tenant header"
rm -rf "$tmp" "$metrics"

# OT7. A --recipe call emits delegate.recipe as a span attribute; a bare
# call omits it.
tmp=$(mktemp -d)
sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
# Probe-aware mock (canary ok) that also answers /v1/traces.
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;;
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
  printf '%s' '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}'
  exit 0
fi
echo "dispatch" >> "${invocations}"
echo "\$payload" > "${sniff}"
body='{"choices":[{"message":{"content":"mock-model-output: ok\\n"},"finish_reason":"stop"}]}'
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
# The body line "RECIPE BODY" only starts with the delimiter; bash does not end
# the heredoc there, shellcheck's parser thinks it does.
# shellcheck disable=SC1122
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
assert_contains '"recipe":"otel-recipe"' "$(cat "$metrics")" "OT7: metrics row carries recipe field"
rm -rf "$tmp" "$metrics"

# OT8. A pick-model failure still emits a span, with status ERROR (code 2).
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
MOCK_MODELS='qwen3.6:35b-a3b'
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

# OT9. DELEGATE_OTEL_VERBOSE=1 names an export failure on stderr.
tmp=$(mktemp -d)
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

# OT10. With verbose unset an export failure is silent.
tmp=$(mktemp -d)
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

# OT11. trace_id / span_id are written to the row even with the exporter
# unset, so a later feedback span can still link to it.
tmp=$(mktemp -d)
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

# OT12. DELEGATE_OTEL_HEADERS url-decodes values (OTel SDK convention), so a
# comma encoded as %2C survives the comma split between headers.
tmp=$(mktemp -d)
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_HEADERS="Cookie: a%3D1%2C%20b%3D2, X-Tenant: y" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT12: url-encoded comma in header → exits 0"
otel_args_line=$(grep '^otel' "$invocations" | head -1)
assert_contains "Cookie: a=1, b=2" "$otel_args_line" "OT12: header value's literal comma round-trips after url-decode"
assert_contains "X-Tenant: y" "$otel_args_line" "OT12: second header still parsed after comma-bearing first header"
# Content-Type + Cookie + X-Tenant; a fragmented Cookie would make four.
h_count=$(echo "$otel_args_line" | grep -oE '\-H ' | wc -l | tr -d ' ')
assert_eq 3 "$h_count" "OT12: exactly three -H flags (Content-Type + Cookie + X-Tenant) — not four (would mean Cookie fragmented)"
rm -rf "$tmp" "$metrics"

# OT13. int64 attribute values are JSON strings per the proto3 JSON mapping;
# status.code and span.kind are int32 enums and stay numbers.
tmp=$(mktemp -d)
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
# jq reports the JSON type; a substring match would conflate `"0"` and `0`.
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
kind_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].kind | type')
assert_eq "number" "$kind_type" "OT13: span.kind stays a JSON number (int32 enum)"
status_code_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].status.code | type')
assert_eq "number" "$status_code_type" "OT13: status.code stays a JSON number (int32 enum)"
start_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].startTimeUnixNano | type')
assert_eq "string" "$start_type" "OT13: startTimeUnixNano is JSON string (fixed64)"
end_type=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].endTimeUnixNano | type')
assert_eq "string" "$end_type" "OT13: endTimeUnixNano is JSON string (fixed64)"
rm -rf "$tmp" "$metrics"

# --- Privacy redaction (#158): DELEGATE_OTEL_INCLUDE_CONTENT=1 opts the
# delegate.prompt/context/output attributes in; unset omits them entirely ---

# OT14. Default redaction: metadata present, content keys absent, and the
# content text itself appears nowhere in the body.
tmp=$(mktemp -d)
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
assert_contains '"delegate.tier"' "$otel_body" "OT14: metadata delegate.tier present"
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT14: metadata delegate.prompt_chars present"
assert_contains '"delegate.context_chars"' "$otel_body" "OT14: metadata delegate.context_chars present"
assert_contains '"delegate.output_chars"' "$otel_body" "OT14: metadata delegate.output_chars present"
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
case "$otel_body" in
  *'mock-model-output: ok'*)
    echo "  FAIL  OT14: model output text MUST NOT appear in payload"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: model output text omitted from body"
    pass=$((pass+1));;
esac
# The schema is omission, not a placeholder.
case "$otel_body" in
  *'<redacted>'*)
    echo "  FAIL  OT14: no '<redacted>' sentinel should leak into the body"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT14: no '<redacted>' sentinel in body (omission, not placeholder)"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT15. DELEGATE_OTEL_INCLUDE_CONTENT=1: the three content attributes carry
# their values and the metadata stays.
tmp=$(mktemp -d)
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
assert_contains '"delegate.prompt"' "$otel_body" "OT15: delegate.prompt key present when opt-in"
assert_contains '"delegate.context"' "$otel_body" "OT15: delegate.context key present when opt-in"
assert_contains '"delegate.output"' "$otel_body" "OT15: delegate.output key present when opt-in"
assert_contains "$SENTINEL_PROMPT" "$otel_body" "OT15: prompt text preserved verbatim when opt-in"
assert_contains "$SENTINEL_CONTEXT" "$otel_body" "OT15: context text preserved verbatim when opt-in"
assert_contains 'mock-model-output: ok' "$otel_body" "OT15: output text preserved verbatim when opt-in"
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT15: char-count metadata still present"
assert_contains '"delegate.tier"' "$otel_body" "OT15: tier metadata still present"
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

# OT16. An explicit =0 redacts like unset.
tmp=$(mktemp -d)
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

# OT17. Only the literal "1" enables include-content; =true stays redacted.
tmp=$(mktemp -d)
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

# --- Sampler overrides (#193): greedy for every model by default; the four
# DELEGATE_TEMPERATURE / TOP_P / TOP_K / PRESENCE_PENALTY env vars opt in per
# call, and the row carries sampling_* keys only for those the caller set ---

# QS1. A Qwen model with no overrides is greedy on the payload and the row.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS1: Qwen model with no overrides exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0' "$payload" "QS1: bare greedy payload has temperature:0"
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

# QS2. A non-Qwen model is greedy by default too.
tmp=$(mktemp -d)
MOCK_MODELS='deepseek-r1:32b'
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" reasoning "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS2: non-Qwen model exits 0"
payload=$(cat "$sniff")
assert_contains '"model":"deepseek-r1:32b"' "$payload" "QS2: model resolved to deepseek-r1"
assert_contains '"temperature":0' "$payload" "QS2: non-Qwen payload has bare temperature:0"
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

# QS3. All four env vars set: the payload and the row carry each value.
tmp=$(mktemp -d)
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

# QS3b. Only DELEGATE_TEMPERATURE set: the others stay off the payload and the row.
tmp=$(mktemp -d)
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

# QS4b. Each override validates independently.
for vname in DELEGATE_TOP_P DELEGATE_TOP_K DELEGATE_PRESENCE_PENALTY; do
  tmp=$(mktemp -d)
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

# QS4c. Shapes a `[!0-9.-]` character class would let through but jq
# --argjson rejects must fail with the validator's own error, not jq's.
for bad in "1-2" "5-" ".-" "1.5.6" "-" "."; do
  tmp=$(mktemp -d)
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

# QS4d. Valid numeric shapes still pass.
for good in "0" "1" "-1" "0.7" "1.3" ".5" "1." "-42" "-0.5"; do
  tmp=$(mktemp -d)
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

# QS5. On MLX the overrides land as top-level keys (OpenAI shape), not in
# an `options` object.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
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

# QS5b. A non-numeric override exits 2 on MLX too.
tmp=$(mktemp -d)
make_mock_curl_mlx_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TOP_P=oops \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "QS5b: MLX + bad DELEGATE_TOP_P exits 2"
assert_contains "DELEGATE_TOP_P" "$(cat "$stderr_file")" "QS5b: MLX validator stderr names env var"
rm -rf "$tmp" "$metrics" "$stderr_file"

# QS6. The canary stays greedy regardless of the dispatch profile.
tmp=$(mktemp -d)
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
    printf '%s' '$(mock_models_json $MOCK_MODELS)'
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
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS6: canary + dispatch exits 0"
canary_payload=$(cat "$canary_payload_sniff")
assert_contains '"max_tokens":1' "$canary_payload" "QS6: canary has max_tokens:1"
assert_contains '"temperature":0' "$canary_payload" "QS6: canary stays at temperature:0"
case "$canary_payload" in
  *'"top_p"'*) echo "  FAIL  QS6: canary must NOT carry top_p"; fail=$((fail+1));;
  *) echo "  PASS  QS6: canary omits top_p"; pass=$((pass+1));;
esac
case "$canary_payload" in
  *'"temperature":0.7'*) echo "  FAIL  QS6: canary must not inherit Qwen 0.7"; fail=$((fail+1));;
  *) echo "  PASS  QS6: canary stays greedy"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT18. Pick-model failure with content opt-in: delegate.prompt is emitted,
# and empty content attributes are omitted rather than sent as "" (the same
# convention as delegate.recipe).
tmp=$(mktemp -d)
MOCK_MODELS='unrelated:model'
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" prose "FailurePathSentinel" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "OT18: pick-model failure with opt-in → exit 1"
otel_body=$(cat "$otel_sniff")
assert_contains '"delegate.prompt"' "$otel_body" "OT18: delegate.prompt present on failure span with opt-in"
assert_contains 'FailurePathSentinel' "$otel_body" "OT18: prompt content matches input on failure span"
case "$otel_body" in
  *'"delegate.output"'*)
    echo "  FAIL  OT18: delegate.output MUST be absent when output is empty (gemini consistency fix)"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT18: delegate.output omitted when output_text is empty (consistent with delegate.recipe)"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'"delegate.context"'*)
    echo "  FAIL  OT18: delegate.context MUST be absent when context is empty"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT18: delegate.context omitted when context_text is empty"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# --- flaky_on_models gate: a recipe refuses with exit 4 when the resolved
# model matches a listed case-insensitive substring; DELEGATE_FORCE_FLAKY=1
# overrides ---

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

# F1. The resolved model matches a pattern: exit 4 before the canary, and
# stderr names recipe, model, pattern and the override.
tmp=$(mktemp -d)
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
if [[ -s "$metrics" ]]; then
  metrics_row=$(tail -1 "$metrics")
  assert_contains '"exit_status":4' "$metrics_row" "flaky-gate: metrics row tagged exit_status:4"
  assert_contains '"recipe":"flaky-recipe"' "$metrics_row" "flaky-gate: metrics row names the recipe"
else
  echo "  FAIL  flaky-gate: metrics row not written"
  fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# F2. DELEGATE_FORCE_FLAKY=1 overrides the gate.
tmp=$(mktemp -d)
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

# F3. No pattern matches: the request proceeds.
tmp=$(mktemp -d)
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

# F4. A recipe without the frontmatter skips the gate.
tmp=$(mktemp -d)
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

# F5. The match is case-insensitive: an uppercase pattern matches the
# lowercase resolved model.
tmp=$(mktemp -d)
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

# 30. DELEGATE_STRIP_THINK strips a leading <think>...</think> trace.

# 30a. Strip on: only the answer reaches stdout.
tmp=$(mktemp -d)
make_mock_curl_think "$tmp" '<think>\nLet me work through this carefully.\n</think>\n\nCLEAN_ANSWER_123'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "CLEAN_ANSWER_123" "$out" "strip-think on: only the answer remains, trace removed"
rm -rf "$tmp" "$metrics"

# 30b. Strip OFF (default): the full trace is preserved on stdout.
tmp=$(mktemp -d)
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
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_contains "mock-model-output: ok" "$out" "strip-think on, no </think>: no-op passthrough"
rm -rf "$tmp" "$metrics"

# 30d. A closing </think> with no opening tag (the template-prefilled shape)
# still strips to the answer.
tmp=$(mktemp -d)
make_mock_curl_think "$tmp" 'Reasoning emitted with no opening tag.\n</think>\n\nPREFILLED_ANSWER_456'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "PREFILLED_ANSWER_456" "$out" "strip-think on: prefilled-open-tag trace stripped to answer"
rm -rf "$tmp" "$metrics"

# 30e. The reasoning tier strips by default.
tmp=$(mktemp -d)
MOCK_MODELS='deepseek-r1:32b'
make_mock_curl_think "$tmp" '<think>\nreasoning here\n</think>\n\nREASONING_ANSWER_789'
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" reasoning "infer something" </dev/null 2>/dev/null)
assert_eq "REASONING_ANSWER_789" "$out" "strip-think: reasoning tier strips by default (no env set)"
rm -rf "$tmp" "$metrics"

# 30f. DELEGATE_STRIP_THINK=0 disables the strip on the reasoning tier.
tmp=$(mktemp -d)
MOCK_MODELS='deepseek-r1:32b'
make_mock_curl_think "$tmp" '<think>\nreasoning here\n</think>\n\nREASONING_ANSWER_789'
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=0 \
  bash "$SCRIPT" reasoning "infer something" </dev/null 2>/dev/null)
assert_contains "<think>" "$out" "strip-think: reasoning tier + STRIP_THINK=0 preserves trace"
rm -rf "$tmp" "$metrics"

# 31. Flavor profile (ADR 0013): {{flavor_*}} placeholders come from
# scripts/flavor-defaults.sh unless a per-user profile.sh overrides them.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/flav.md" <<'EOF'
# flav

## When to use
Flavor test recipe.

## Prompt template

```
SUBJECT MAX: {{flavor_commit_subject_max}}
TYPES: {{flavor_commit_types}}
```

## Calibration notes
n/a
EOF
# 31a. No profile installed -> shipped defaults fill the placeholders.
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_LOCAL_PROFILE="$tmp/nonexistent.sh" \
  bash "$SCRIPT" --recipe flav prose "go" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "flavor: exits 0 with shipped defaults"
payload=$(cat "$sniff")
assert_contains 'SUBJECT MAX: 72' "$payload" "flavor: default subject max injected"
assert_contains 'TYPES: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert' "$payload" "flavor: default type vocabulary injected"
# 31b. A per-user profile overrides the defaults.
prof="$tmp/profile.sh"
printf 'FLAVOR_COMMIT_SUBJECT_MAX=50\nFLAVOR_COMMIT_TYPES="feat, fix, docs"\n' > "$prof"
chmod 600 "$prof"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_LOCAL_PROFILE="$prof" \
  bash "$SCRIPT" --recipe flav prose "go" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "flavor: exits 0 with profile override"
payload=$(cat "$sniff")
assert_contains 'SUBJECT MAX: 50' "$payload" "flavor: profile override subject max injected"
assert_contains 'TYPES: feat, fix, docs' "$payload" "flavor: profile override type vocabulary injected"
rm -rf "$tmp" "$metrics"

# 32. Output checks (ADR 0014): a recipe's `checks:` block runs on the final
# output, warns on stderr and puts checks_failed=N on the meta line.
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/chk.md" <<'EOF'
---
checks:
  subject_max: 10
  no_padding_tail: true
---
# chk

## When to use
Checks test recipe.

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
# 32a. Both checks fail. The "This-X" padding shape is never auto-stripped,
# so it stays a failure.
make_mock_curl_think "$tmp" 'This first line is far longer than ten chars\n\nthe body works fine. This approach ensures simplicity'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe chk prose "go" </dev/null 2>&1)
assert_contains "check 'subject_max' FAILED" "$out" "checks: subject_max failure reported on stderr"
assert_contains "check 'no_padding_tail' FAILED" "$out" "checks: no_padding_tail failure reported on stderr"
assert_contains "checks_failed=2" "$out" "checks: failure count rides the delegate-meta line"
# 32a-i. The row names which checks failed, in run order.
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["subject_max","no_padding_tail"]' "$row" \
  "checks: metrics row names both failed checks in run order"
# 32b. Clean output -> no FAILED warnings, no checks_failed field.
make_mock_curl_think "$tmp" 'short\n\nthe body returns a structured response and stops'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe chk prose "go" </dev/null 2>&1)
if [[ "$out" == *"FAILED"* || "$out" == *"checks_failed="* ]]; then
  echo "  FAIL  checks: clean output triggers no check warnings"; fail=$((fail+1))
else
  echo "  PASS  checks: clean output triggers no check warnings"; pass=$((pass+1))
fi
# 32c. A participial-comma tail is auto-fixed: stripped, reported as
# AUTO-FIXED, counted as checks_autofixed on the row.
make_mock_curl_think "$tmp" 'short\n\nthe body drops the per-call cost, ensuring nothing regresses'
errf=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe chk prose "go" </dev/null 2>"$errf")
err=$(cat "$errf"); rm -f "$errf"
assert_contains "check 'no_padding_tail' AUTO-FIXED" "$err" "checks: participial tail auto-fixed (not failed)"
assert_contains "checks_autofixed=1" "$err" "checks: autofix count rides the delegate-meta line"
if [[ "$out" == *"ensuring nothing regresses"* ]]; then
  echo "  FAIL  checks: padding clause not stripped from output"; fail=$((fail+1))
else
  echo "  PASS  checks: padding clause stripped from output"; pass=$((pass+1))
fi
if [[ "$out" == *"the body drops the per-call cost"* ]]; then
  echo "  PASS  checks: content before the padding clause is preserved"; pass=$((pass+1))
else
  echo "  FAIL  checks: content before padding clause lost"; fail=$((fail+1))
fi
if grep -q '"checks_autofixed":1' "$metrics"; then
  echo "  PASS  checks: checks_autofixed persisted to metrics"; pass=$((pass+1))
else
  echo "  FAIL  checks: checks_autofixed missing from metrics"; fail=$((fail+1))
fi
# 32d. DELEGATE_NO_AUTOFIX=1 restores warn-only: the same tail FAILS, not fixed.
make_mock_curl_think "$tmp" 'short\n\nthe body drops the per-call cost, ensuring nothing regresses'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_AUTOFIX=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe chk prose "go" </dev/null 2>&1)
assert_contains "check 'no_padding_tail' FAILED" "$out" "checks: DELEGATE_NO_AUTOFIX restores warn-only"
if [[ "$out" == *"AUTO-FIXED"* ]]; then
  echo "  FAIL  checks: NO_AUTOFIX still auto-fixed"; fail=$((fail+1))
else
  echo "  PASS  checks: NO_AUTOFIX did not strip"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# 33. no_padding_tail's participial arm matches any gerund tail, not an
# enumerated verb list; only allowlisted filler verbs are auto-stripped.
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/pad.md" <<'EOF'
---
checks:
  no_padding_tail: true
---
# pad

## When to use
Padding-check test recipe.

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
# 33a. A gerund the old per-verb list never named is caught.
make_mock_curl_think "$tmp" 'short subject\n\nthe body drops the per-call cost, confirming the need for a matcher'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null 2>&1)
assert_contains "check 'no_padding_tail' AUTO-FIXED" "$out" "checks: structural matcher catches+auto-fixes unenumerated gerund tail"
# 33b. A clean finite-verb tail is not flagged.
make_mock_curl_think "$tmp" 'short subject\n\nthe body drops the per-call cost and stops here'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null 2>&1)
if [[ "$out" == *"no_padding_tail' FAILED"* ]]; then
  echo "  FAIL  checks: clean finite-verb tail not flagged"; fail=$((fail+1))
else
  echo "  PASS  checks: clean finite-verb tail not flagged"; pass=$((pass+1))
fi
# 33c. An allowlisted verb with a further comma after it is detected but not
# auto-stripped, so no real content is removed.
make_mock_curl_think "$tmp" 'short subject\n\nthe list is built, ensuring order, then returned to the caller'
errf=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null 2>"$errf")
err=$(cat "$errf"); rm -f "$errf"
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: ambiguous multi-comma tail not auto-stripped (stays a warning)"
if [[ "$out" == *"then returned to the caller"* ]]; then
  echo "  PASS  checks: ambiguous tail content preserved (not stripped)"; pass=$((pass+1))
else
  echo "  FAIL  checks: ambiguous tail was wrongly stripped"; fail=$((fail+1))
fi
# 33d. A gerund outside the allowlist is detected but not auto-stripped.
make_mock_curl_think "$tmp" 'short subject\n\nthe cache is rebuilt, surfacing the new latency numbers'
errf=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null 2>"$errf")
err=$(cat "$errf"); rm -f "$errf"
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: non-allowlisted gerund detected but not auto-stripped"
if [[ "$out" == *"surfacing the new latency numbers"* ]]; then
  echo "  PASS  checks: non-allowlisted participial preserved"; pass=$((pass+1))
else
  echo "  FAIL  checks: non-allowlisted participial wrongly stripped"; fail=$((fail+1))
fi
# 33e. A participial followed by a further sentence is not a tail: the arm
# is anchored to the end of the line.
make_mock_curl_think "$tmp" 'short subject\n\nthe block is deleted, leaving the actions block unchanged. the fix is verified by the next run'
errf=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null >/dev/null 2>"$errf"
err=$(cat "$errf"); rm -f "$errf"
if [[ "$err" == *"no_padding_tail"* ]]; then
  echo "  FAIL  checks: mid-line participial wrongly flagged as a padding tail"; fail=$((fail+1))
else
  echo "  PASS  checks: mid-line participial followed by a sentence not flagged"; pass=$((pass+1))
fi
# 33f. The same shape with a semicolon-joined continuation.
make_mock_curl_think "$tmp" 'short subject\n\nauto-strip the padding clause on a filler-verb allowlist, adopting the strip only when it clears the padding; persist the counters to metrics so quality is observable. default-on with an opt-out'
errf=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null >/dev/null 2>"$errf"
err=$(cat "$errf"); rm -f "$errf"
if [[ "$err" == *"no_padding_tail"* ]]; then
  echo "  FAIL  checks: hand-written mid-line participial wrongly flagged"; fail=$((fail+1))
else
  echo "  PASS  checks: hand-written mid-line participial not flagged"; pass=$((pass+1))
fi
# 33g. A tail may contain commas but not cross a sentence boundary, which is
# why the class is [^.!?]* and not [^,.!?]*.
make_mock_curl_think "$tmp" 'short subject\n\nthe change lands, ensuring the cache, the limiter and the queue stay in sync'
errf=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null >/dev/null 2>"$errf"
err=$(cat "$errf"); rm -f "$errf"
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: padding tail with an internal comma still detected"
# 33h. `ing` must be a word ending, or every `-ings` plural is a false positive.
make_mock_curl_think "$tmp" 'short subject\n\nreads the flag from the repo config, settings are merged per section'
errf=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null >/dev/null 2>"$errf"
err=$(cat "$errf"); rm -f "$errf"
if [[ "$err" == *"no_padding_tail"* ]]; then
  echo "  FAIL  checks: -ings plural wrongly treated as a gerund tail"; fail=$((fail+1))
else
  echo "  PASS  checks: -ings plural not treated as a gerund tail"; pass=$((pass+1))
fi
# 33i. The adoption gate (ADR 0017) stays broad: a strip whose result still
# carries a mid-line participial is rejected, not silently adopted.
make_mock_curl_think "$tmp" 'short subject\n\nadds a cache, improving latency. also fixes the lock, ensuring parity'
errf=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe pad prose "go" </dev/null 2>"$errf")
err=$(cat "$errf"); rm -f "$errf"
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: adoption gate still rejects a not-clean strip"
if [[ "$out" == *"ensuring parity"* ]]; then
  echo "  PASS  checks: adoption unchanged, output not silently mutated"; pass=$((pass+1))
else
  echo "  FAIL  checks: adoption widened, output was silently stripped"; fail=$((fail+1))
fi
# subject_type recipe: optional type input echoed into the check value.
cat > "$prompts/typ.md" <<'EOF'
---
inputs:
  type: string?
checks:
  subject_type: {{type}}
---
# typ

## When to use
Subject-type check test recipe.

## Prompt template

```
GO {{type}}
```

## Variables
- `{{type}}` — optional conventional-commit type.

## Calibration notes
n/a
EOF
# 33c. Provided type the subject ignores -> FAILED.
make_mock_curl_think "$tmp" 'feat: did a thing\n\nbody'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typ --var type=fix prose "go" </dev/null 2>&1)
assert_contains "check 'subject_type' FAILED" "$out" "checks: subject_type flags an ignored --var type override"
# 33d. Provided type the subject honours (with a scope) -> no failure.
make_mock_curl_think "$tmp" 'fix(core): did a thing\n\nbody'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typ --var type=fix prose "go" </dev/null 2>&1)
if [[ "$out" == *"subject_type' FAILED"* ]]; then
  echo "  FAIL  checks: subject_type passes when subject carries the type"; fail=$((fail+1))
else
  echo "  PASS  checks: subject_type passes when subject carries the type"; pass=$((pass+1))
fi
# 33e. Omitted optional type -> placeholder blanked in the checks block, skipped.
make_mock_curl_think "$tmp" 'anything goes here\n\nbody'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typ prose "go" </dev/null 2>&1)
if [[ "$out" == *"subject_type' FAILED"* || "$out" == *"{{type}}"* ]]; then
  echo "  FAIL  checks: subject_type skipped when optional type omitted"; fail=$((fail+1))
else
  echo "  PASS  checks: subject_type skipped when optional type omitted"; pass=$((pass+1))
fi
# body_required recipe: fail a subject-only output, pass a subject+body.
cat > "$prompts/bodyreq.md" <<'EOF'
---
checks:
  body_required: true
---
# bodyreq

## When to use
Body-required check test recipe.

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
# 33f. Subject-only output (no body) -> body_required FAILED + checks_failed=1.
make_mock_curl_think "$tmp" 'feat: a subject with no body'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe bodyreq prose "go" </dev/null 2>&1)
assert_contains "check 'body_required' FAILED" "$out" "checks: body_required flags a subject-only output"
assert_contains "checks_failed=1" "$out" "checks: body_required failure rides the delegate-meta line"
# 33g. Subject + blank line + body -> body_required not flagged.
make_mock_curl_think "$tmp" 'feat: a subject\n\nthe body explains the change in full'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe bodyreq prose "go" </dev/null 2>&1)
if [[ "$out" == *"body_required' FAILED"* || "$out" == *"checks_failed="* ]]; then
  echo "  FAIL  checks: body_required passes when a body is present"; fail=$((fail+1))
else
  echo "  PASS  checks: body_required passes when a body is present"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- #277 dir 5: --recipe auto inference -----------------------------------
read -r -d '' DIFF_SAMPLE <<'DIFF' || true
diff --git a/foo.txt b/foo.txt
index e69de29..4b825dc 100644
--- a/foo.txt
+++ b/foo.txt
@@ -0,0 +1 @@
+hello
DIFF

# A1. --recipe auto + piped diff resolves to commit-message. recent_commits
# and diff_stat are passed so the git backfill (A4) is skipped.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/commit-message.md" <<'EOF'
# commit-message

## When to use
Stub.

## Prompt template

```
RECENT
{{recent_commits}}
STAT
{{diff_stat}}
WHY
{{why}}
```

## Calibration notes
n/a
EOF
EC=0
err="$tmp/err.txt"
out=$(printf '%s' "$DIFF_SAMPLE" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto --var recent_commits=rc --var diff_stat=ds --var why=because prose "go" 2>"$err") || EC=$?
assert_eq 0 "$EC" "--recipe auto (diff): exits 0"
assert_contains "inferred commit-message" "$(cat "$err")" "--recipe auto (diff): announces inference on stderr"
assert_contains '"recipe":"commit-message"' "$(cat "$metrics")" "--recipe auto (diff): metrics recipe=commit-message"
payload=$(cat "$sniff")
assert_contains 'WHY' "$payload" "--recipe auto (diff): commit-message template used"
assert_contains 'because' "$payload" "--recipe auto (diff): {{why}} from --var substituted"
rm -rf "$tmp" "$metrics"

# A2. --recipe auto + non-diff context -> exit 2, clear "could not infer".
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(printf 'just some prose, not a diff at all' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto prose "go" 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe auto (non-diff): exit 2"
assert_contains "could not infer" "$out" "--recipe auto (non-diff): clear error"
rm -rf "$tmp" "$metrics"

# A3. --recipe auto with no piped context -> exit 2, "needs context".
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto prose "go" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe auto (no stdin): exit 2"
assert_contains "needs context" "$out" "--recipe auto (no stdin): clear error"
rm -rf "$tmp" "$metrics"

# A stub commit-message recipe with the three placeholders the auto path fills.
make_auto_cm_recipe() {
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/commit-message.md" <<'EOF'
# commit-message

## When to use
Stub.

## Prompt template

```
RECENT
{{recent_commits}}
STAT
{{diff_stat}}
WHY
{{why}}
```

## Calibration notes
n/a
EOF
}

# A4. diff_stat comes from the piped diff, not the index (the repo stages
# a.txt, the diff names foo.txt); recent_commits is backfilled from git log.
if command -v git >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  sniff="$tmp/payload.json"
  make_mock_curl_ok "$tmp" "$sniff"
  metrics=$(mktemp); : > "$metrics"
  prompts="$tmp/prompts"; make_auto_cm_recipe "$prompts"
  repo="$tmp/gitrepo"; mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email t@t.t; git config user.name t
    printf 'one\n' > a.txt; git add a.txt; git commit -qm "initial commit"
    printf 'two\n' >> a.txt; git add a.txt
  )
  EC=0
  out=$(cd "$repo" && printf '%s' "$DIFF_SAMPLE" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe auto --var why=because prose "go") || EC=$?
  assert_eq 0 "$EC" "--recipe auto (backfill): exit 0 with only --var why"
  payload=$(cat "$sniff")
  assert_contains 'initial commit' "$payload" "--recipe auto (backfill): recent_commits from git log"
  assert_contains 'foo.txt' "$payload" "--recipe auto (backfill): diff_stat derived from the piped diff"
  if [[ "$payload" == *"a.txt"* ]]; then
    echo "  FAIL  --recipe auto (backfill): diff_stat leaked git index (a.txt) instead of piped diff"; fail=$((fail+1))
  else
    echo "  PASS  --recipe auto (backfill): diff_stat does NOT leak the staged index file"; pass=$((pass+1))
  fi
  # The backfilled exemplar keeps bodies but drops trailer lines (#501): a
  # Refs or Co-Authored-By line copied from a prior commit names the wrong
  # issue every time, and no_example_echo only catches it after the fact.
  # GitHub's own squash trailer is spelled Co-authored-by, so the filter is
  # case-insensitive and every trailer it names is exercised.
  ( cd "$repo" && git commit -q --allow-empty -m "feat: second commit" -m "A body line that stays." \
      -m "Refs: #999" -m "Co-Authored-By: Someone <s@x.y>" -m "Co-authored-by: GitHub Squash <g@x.y>" \
      -m "Claude-Session: https://claude.ai/code/session_TRAILER" -m "Signed-off-by: Dev <d@x.y>" )
  : > "$sniff"
  EC=0
  out=$(cd "$repo" && printf '%s' "$DIFF_SAMPLE" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe auto --var why=because prose "go") || EC=$?
  payload=$(cat "$sniff")
  assert_contains 'A body line that stays.' "$payload" "--recipe auto (backfill): commit bodies are kept as shape anchors"
  for trailer in "Refs: #999" "Co-Authored-By" "Co-authored-by" "Claude-Session" "Signed-off-by"; do
    if [[ "$payload" == *"$trailer"* ]]; then
      echo "  FAIL  --recipe auto (backfill): $trailer leaked into recent_commits (#501)"; fail=$((fail+1))
    else
      echo "  PASS  --recipe auto (backfill): $trailer is stripped from recent_commits (#501)"; pass=$((pass+1))
    fi
  done
  rm -rf "$tmp" "$metrics"

  # A5. A clean tree with the diff piped from elsewhere still fills diff_stat.
  tmp=$(mktemp -d)
  sniff="$tmp/payload.json"
  make_mock_curl_ok "$tmp" "$sniff"
  metrics=$(mktemp); : > "$metrics"
  prompts="$tmp/prompts"; make_auto_cm_recipe "$prompts"
  repo="$tmp/gitrepo2"; mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email t@t.t; git config user.name t
    printf 'one\n' > a.txt; git add a.txt; git commit -qm "initial commit"
  )  # nothing staged after the commit — clean tree
  EC=0
  out=$(cd "$repo" && printf '%s' "$DIFF_SAMPLE" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe auto --var why=because prose "go" 2>&1) || EC=$?
  assert_eq 0 "$EC" "--recipe auto (clean tree): exit 0 — diff_stat from piped diff, no hard-fail"
  rm -rf "$tmp" "$metrics"
else
  echo "  SKIP  --recipe auto (backfill): git not on PATH"
fi

# A6. A diff larger than the pipe buffer (#480): the sniff used to run
# `printf | grep -q`, and grep exiting on line one left printf with SIGPIPE, so
# every diff over ~64 KiB fell through to "could not infer" under pipefail.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/commit-message.md" <<'EOF2'
# commit-message

## When to use
Stub.

## Prompt template

```
WHY
{{why}}
```

## Calibration notes
n/a
EOF2
big_diff=$(printf '%s\n' "$DIFF_SAMPLE"; awk 'BEGIN { for (i = 0; i < 3000; i++) printf "+%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }')
EC=0
err="$tmp/err.txt"
out=$(printf '%s' "$big_diff" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto --var recent_commits=rc --var diff_stat=ds --var why=because prose "go" 2>"$err") || EC=$?
assert_eq 0 "$EC" "--recipe auto (>64 KiB diff): exits 0, not 'could not infer' (#480)"
assert_contains '"recipe":"commit-message"' "$(cat "$metrics")" "--recipe auto (>64 KiB diff): metrics recipe=commit-message"
rm -rf "$tmp" "$metrics"

# N. An unknown tier (pick-model exit 2) and a real tier with no model (exit
# 1) need opposite remedies, so delegate.sh must keep them apart.
tmp=$(mktemp -d)
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" small "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "unknown tier -> exit 2 (usage error, not exit 1)"
assert_contains "unknown tier: small" "$out" "unknown tier: names the bad tier"
assert_contains "code|prose|reasoning|long-context" "$out" "unknown tier: lists the valid tiers"
assert_contains "nothing needs installing" "$out" "unknown tier: does not send the caller to install a model"
case "$out" in
  *"no installed model matches this tier"*)
    echo "  FAIL  unknown tier: still emits the misleading no-installed-model advice"; fail=$((fail+1));;
  *) echo "  PASS  unknown tier: suppresses the misleading no-installed-model advice"; pass=$((pass+1));;
esac
assert_contains '"exit_status":2' "$(cat "$metrics")" "unknown tier: metrics row tagged exit_status 2"
rm -rf "$tmp" "$metrics"

# A valid tier that resolves to nothing keeps exit 1 and the install advice.
tmp=$(mktemp -d)
MOCK_MODELS=''
make_mock_curl_models_only "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "valid but unresolvable tier -> exit 1"
assert_contains "no installed model matches this tier" "$out" "unresolvable tier: keeps install-a-model advice"
assert_contains '"exit_status":1' "$(cat "$metrics")" "unresolvable tier: metrics row tagged exit_status 1"
rm -rf "$tmp" "$metrics"

# --- #342: the caller can state the project the delegation is for, since the
# cwd derivation is wrong when delegate.sh runs from another checkout ---
tmp=$(mktemp -d)
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROJECT=repo-butler \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "DELEGATE_PROJECT: exits 0"
assert_eq repo-butler "$(jq -r .project < "$metrics")" "DELEGATE_PROJECT overrides the cwd-derived project"
: > "$metrics"

# --project NAME does the same and wins over the env var.
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROJECT=from-env \
  bash "$SCRIPT" --project from-flag prose "Summarise" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "--project: exits 0"
assert_eq from-flag "$(jq -r .project < "$metrics")" "--project wins over DELEGATE_PROJECT"
: > "$metrics"

# The --project=NAME form is accepted too.
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --project=teams-for-linux prose "Summarise" </dev/null >/dev/null 2>&1
assert_eq teams-for-linux "$(jq -r .project < "$metrics")" "--project=NAME form accepted"
: > "$metrics"

# Neither set and the cwd outside any git repository: no project at all, since
# a throwaway directory's basename is not a project name.
(cd "$tmp" && env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1)
assert_eq "false" "$(jq -r 'has("project")' < "$metrics")" \
  "no override outside a repo: the row carries no project"

# --project with no value is a usage error, not a silently empty project.
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --project </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--project without a value -> exit 2"
assert_contains "--project requires a value" "$out" "--project without a value: informative stderr"

# A following flag is the next option, not the value.
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --project --recipe commit-message prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--project followed by a flag -> exit 2"
assert_contains "--project requires a value" "$out" "--project followed by a flag: informative stderr"
rm -rf "$tmp" "$metrics"

# 34. The dispatch curl carries --max-time (default 600 s) and --connect-timeout.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_argv "$tmp" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 600" "$argv" "ollama dispatch defaults to 600s"
assert_contains "--connect-timeout 5" "$argv" "ollama dispatch passes --connect-timeout"
rm -rf "$tmp"

# 35. DELEGATE_REQUEST_TIMEOUT overrides the default.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_argv "$tmp" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_REQUEST_TIMEOUT=42 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 42" "$argv" "DELEGATE_REQUEST_TIMEOUT overrides the default"
rm -rf "$tmp"

# 36. The MLX dispatch curl gets the same bounds.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 600" "$argv" "mlx dispatch defaults to 600s"
assert_contains "--connect-timeout 5" "$argv" "mlx dispatch passes --connect-timeout"
rm -rf "$tmp"

# 37. A timeout (curl exit 28) names the knob to raise.
tmp=$(mktemp -d)
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
# Discovery: pick-model.sh probes GET {base}/models before any dispatch, and
# that request has no stdin, so this arm answers and exits before anything
# reads stdin.
for _a in "$@"; do
  case "$_a" in */models) printf '%s' '{"object":"list","data":[{"id":"qwen3.6:35b-a3b"}]}'; exit 0 ;; esac
done
cat > /dev/null
echo "curl: (28) Operation timed out" >&2
exit 28
EOF
chmod +x "$tmp/curl"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || true
assert_contains "DELEGATE_REQUEST_TIMEOUT" "$out" "timeout guidance names the knob"
rm -rf "$tmp"

make_mock_curl_provider() {
  # For the DELEGATE_BASE_URL path: answers {base}/models with a populated
  # list, records dispatch argv to $3, returns a chat-completions body.
  local dir="$1" payload_sniff="${2:-/dev/null}" argv_sniff="${3:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"/models"*)
      cat > /dev/null
      printf '%s' '{"object":"list","data":[{"id":"qwen3.6-provider-test","object":"model"}]}'
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
body='{"choices":[{"message":{"role":"assistant","content":"provider-output-ok"},"finish_reason":"stop"}]}'
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

# 38. DELEGATE_BASE_URL dispatches to {base}/chat/completions on the resolved provider.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "provider dispatch exits 0"
assert_contains "provider-output-ok" "$out" "provider dispatch parses .choices[0].message.content"
argv=$(cat "$argv_sniff")
assert_contains "http://localhost:12434/engines/v1/chat/completions" "$argv" "provider dispatch posts to {base}/chat/completions"
assert_contains '"backend":"docker"' "$(cat "$metrics")" "provider dispatch labels metrics by provider, not a flat 'provider'"
rm -rf "$tmp" "$metrics"

# 39. The provider dispatch keeps the timeout bound.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff")
assert_contains "--max-time 600" "$argv" "provider dispatch keeps the 600s bound"
rm -rf "$tmp"

# 40. A trailing slash on the base URL does not produce a doubled slash.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1/" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff")
assert_contains "engines/v1/chat/completions" "$argv" "trailing slash is stripped once"
rm -rf "$tmp"

# 41. An unknown host is labelled host:port so two stay distinguishable.
tmp=$(mktemp -d)
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$tmp/argv.txt"
metrics=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_BASE_URL="http://localhost:9999/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
assert_contains '"backend":"localhost:9999"' "$(cat "$metrics")" "unknown provider is labelled host:port"
rm -rf "$tmp" "$metrics"

# 42. A provider on Ollama's port is labelled ollama but still dispatched
# through the OpenAI arm, never the native /api/generate branch.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_BASE_URL="http://localhost:11434/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || true
argv=$(cat "$argv_sniff")
assert_contains "http://localhost:11434/v1/chat/completions" "$argv" "ollama-port provider still posts to {base}/chat/completions"
case "$argv" in
  *"/api/generate"*) assert_eq "openai arm" "native ollama arm" "ollama-port provider does not fall back to /api/generate" ;;
  *) assert_eq "openai arm" "openai arm" "ollama-port provider does not fall back to /api/generate" ;;
esac
assert_contains '"backend":"ollama"' "$(cat "$metrics")" "ollama-port provider is still labelled ollama in metrics"
rm -rf "$tmp" "$metrics"

# 43. A --var value that is only an angle-bracket stand-in copied from a
# recipe's Invocation block is rejected before dispatch, naming the key (#356).
for placeholder in \
  '<why this changed>' \
  '<the git diff --cached --stat output>' \
  '<one or two sentences>' \
  '<sentences>' \
  '<type>'; do
  out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
    bash "$SCRIPT" --recipe commit-message --var why="$placeholder" prose </dev/null 2>&1); rc=$?
  # Exit 2 alone is not enough: the recipe also exits 2 for missing inputs.
  assert_eq "2" "$rc" "placeholder '$placeholder' exits 2"
  assert_contains "unreplaced placeholder" "$out" "placeholder '$placeholder' is reported as such"
  assert_contains "why" "$out" "placeholder '$placeholder' names the offending key"
done

# 44. Values that merely contain angle brackets (HTML, generics, redirects)
# pass; they may fail later for other reasons, the assertion is only that
# they are not rejected as placeholders.
for legit in \
  'if (a < b) { x } else if (c > d) { y }' \
  'std::vector<int> v; if (a < b) return;' \
  'cmd < in.txt > out.txt' \
  '<div class="x">hello</div>' \
  'foo(a<b, c>d)' \
  '+  <span>ok</span>'; do
  out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
    bash "$SCRIPT" --recipe commit-message --var diff="$legit" prose </dev/null 2>&1) || true
  case "$out" in
    *"unreplaced placeholder"*)
      assert_eq "accepted" "rejected" "legitimate value is not flagged: $legit" ;;
    *)
      assert_eq "accepted" "accepted" "legitimate value is not flagged: $legit" ;;
  esac
done

make_mock_curl_empty() {
  # A well-formed response whose answer is empty with finish_reason "length".
  # Serves /v1/models too, so the test cannot pass on a resolution failure.
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    http*) url="$1"; shift;;
    *) shift;;
  esac
done
# Answer the probe before draining stdin: the models request has no stdin and
# a blocking `cat` would hang the run.
case "$url" in
  */models) printf '%s' '{"data":[{"id":"qwen3.6:35b-a3b"}]}'; exit 0 ;;
esac
cat >/dev/null
body='{"choices":[{"message":{"content":"","reasoning":"thinking hard"},"finish_reason":"length"}]}'
if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; printf '0.001'; else printf '%s' "$body"; fi
EOF
  chmod +x "$dir/curl"
}

# 45. An empty answer (reasoning ate the token budget, finish_reason
# "length") is reported with exit 100, not returned as a silent success.
tmp=$(mktemp -d)
make_mock_curl_empty "$tmp"
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_BASE_URL="http://localhost:9999/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1); rc=$?
assert_eq "100" "$rc" "empty answer exits with the empty-response sentinel"
assert_contains "empty response" "$out" "empty answer is reported as such"
assert_contains "finish_reason=length" "$out" "empty answer names the finish reason"
assert_contains "DELEGATE_MAX_TOKENS" "$out" "empty answer points at the token budget"
# The sentinel must not be diagnosed as a transport failure.
case "$out" in
  *"dispatch failed (curl exit"*)
    assert_eq "no curl advice" "curl advice printed" "empty answer does not print transport advice" ;;
  *)
    assert_eq "no curl advice" "no curl advice" "empty answer does not print transport advice" ;;
esac
assert_contains '"exit_status":100' "$(cat "$metrics")" "empty answer is visible in the metrics row"
rm -rf "$tmp" "$metrics"

# 46. `--tier NAME` (#411) wins over the positional tier and moves the prompt
# to the first positional; the historical `<tier> ["<prompt>"]` order is untouched.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier prose "Summarise this" </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier sets the tier"
assert_contains "Summarise this" "$(cat "$tmp/payload.json")" "--tier moves the prompt to the first positional"
rm -rf "$tmp" "$metrics"

# `code` is unresolvable with this mock's single prose model, so a pass
# proves the flag won rather than agreeing with the positional.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier prose code "Summarise" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "--tier overrides the positional tier"
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier overrides the positional tier in metrics"
rm -rf "$tmp" "$metrics"

# --tier=NAME is accepted too.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier=prose "Summarise" </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier=NAME sets the tier"
rm -rf "$tmp" "$metrics"

# A following flag is the next option, not the value.
tmp=$(mktemp -d)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" --tier --recipe commit-message prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--tier followed by a flag -> exit 2"
assert_contains "--tier requires a value" "$out" "--tier followed by a flag: informative stderr"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" --tier </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--tier without a value -> exit 2"
rm -rf "$tmp"

# An unrecognised flag in the tier slot is diagnosed as a flag, not an
# invented tier; the metrics row still records it, which is what surfaced the bug.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --file "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "an unknown flag in the tier slot -> exit 2"
assert_contains "is not a flag delegate.sh knows" "$out" "unknown flag is diagnosed as a flag, not a tier"
assert_contains "--tier --file" "$out" "unknown flag names --tier as the alternative"
assert_contains '"tier":"--file"' "$(cat "$metrics")" "unknown flag still writes its metrics row"
rm -rf "$tmp" "$metrics"

# A dash-leading prompt works without `--`: it is the second positional and
# never reaches the option parser.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "-not a flag" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "a dash-leading prompt still works without --"
assert_contains "-not a flag" "$(cat "$tmp/payload.json")" "a dash-leading prompt reaches the model intact"
rm -rf "$tmp" "$metrics"

# The historical positional order is untouched.
tmp=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise this" </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "positional tier still works"
assert_contains "Summarise this" "$(cat "$tmp/payload.json")" "positional prompt still works"
rm -rf "$tmp" "$metrics"

out=$(bash "$SCRIPT" </dev/null 2>&1) || true
assert_contains "tier NAME is equivalent" "$out" "usage advertises --tier"

# 47. A recipe's frontmatter `tier:` supplies the tier when no positional does (#411).
mk_recipe() {  # mk_recipe <dir> <name> [tier]
  local dir="$1" name="$2" tier="${3:-}"
  { printf -- '---\n'
    [[ -n "$tier" ]] && printf 'tier: %s\n' "$tier"
    printf -- 'inputs:\n  note: string?\n---\n# %s\n\n## Prompt template\n\n```\nSay OK.\n```\n' "$name"
  } > "$dir/$name.md"
}

for pair in "prose r_prose" "reasoning r_reason" "code r_code"; do
  set -- $pair
  want="$1"; rname="$2"
  tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
  make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
  mk_recipe "$pdir" "$rname" "$want"
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
    DELEGATE_METRICS_FILE="$metrics" \
    bash "$SCRIPT" --recipe "$rname" </dev/null >/dev/null 2>&1 || true
  assert_contains "\"tier\":\"$want\"" "$(cat "$metrics")" "recipe declaring '$want' resolves it with no positional"
  rm -rf "$tmp" "$pdir" "$metrics"
done

# A lone positional that is a sentence is the prompt, not the tier: most
# recipes pass a trailing reinforcement prompt.
tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
mk_recipe "$pdir" "r_prose" "prose"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_prose "Match the example messages exactly in shape and tone." </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "a lone sentence positional is the prompt, not the tier"
assert_contains '"tier":"prose"' "$(cat "$metrics")" "lone sentence positional keeps the declared tier"
assert_contains "Match the example messages" "$(cat "$tmp/payload.json")" "lone sentence positional reaches the model as the prompt"
rm -rf "$tmp" "$pdir" "$metrics"

# A lone positional that is a tier name is still the tier.
tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
mk_recipe "$pdir" "r_reason" "reasoning"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_reason prose </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "a lone positional matching a tier name is still the tier"
rm -rf "$tmp" "$pdir" "$metrics"

# An explicit tier wins over the declared one.
tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
make_mock_curl_mlx_ok "$tmp" "$tmp/payload.json"
mk_recipe "$pdir" "r_prose" "prose"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_prose --tier code </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"code"' "$(cat "$metrics")" "--tier overrides the recipe's declared tier"
rm -rf "$tmp" "$pdir" "$metrics"

# A recipe with no declared tier and no positional names both remedies.
tmp=$(mktemp -d); pdir=$(mktemp -d)
mk_recipe "$pdir" "r_none"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" --recipe r_none </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "recipe with no declared tier and no positional -> exit 2"
assert_contains "declares no tier" "$out" "no-tier recipe error says so"
assert_contains "tier: <name>" "$out" "no-tier recipe error names the frontmatter remedy"
assert_contains "tier <name> ..." "$out" "no-tier recipe error names the flag remedy"
rm -rf "$tmp" "$pdir"

# Without a recipe the tier stays required, exactly as before.
tmp=$(mktemp -d)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "no recipe and no tier still exits 2"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "no recipe and no prompt still exits 2"
rm -rf "$tmp"


# --- 40. no_example_echo (ADR 0029): on by default for every recipe call,
# fails when the output reproduces a line of the recipe's own prompt ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/anchor.md" <<'EOF'
---
tier: prose
---
# anchor

## When to use
Contrastive-anchor recipe.

## Prompt template

```
Answer using only the facts below.

Wrong: The regression is in the date parser, and ask the reporter to confirm it.
Correct: The regression is in the date parser. Could you confirm whether it also happens on older inputs?

=== Facts ===
{{stdin}}
```

## Calibration notes
n/a
EOF
# 40a. Output that reproduces the Correct: example verbatim -> FAILED + named.
make_mock_curl_think "$tmp" 'The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
out=$(echo "unrelated facts about a config loader" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
assert_contains "check 'no_example_echo' FAILED" "$out" "echo-check: verbatim example reproduction is caught"
assert_contains "REJECT this draft" "$out" "echo-check: stderr tells the caller not to ship it"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_example_echo"]' "$row" "echo-check: named on the metrics row"
# 40b. The label prefix is stripped before comparing, so the Wrong: arm is caught too.
make_mock_curl_think "$tmp" 'The regression is in the date parser, and ask the reporter to confirm it.'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
assert_contains "check 'no_example_echo' FAILED" "$out" "echo-check: echoed Wrong: arm caught after label strip"
# 40b-i. The label is stripped from the output side too, so an echo that
# keeps its `Correct:` label is caught.
make_mock_curl_think "$tmp" 'Correct: The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
assert_contains "check 'no_example_echo' FAILED" "$out" "echo-check: echo that keeps the Correct: label is caught"
# 40b-ii. One normalisation on both sides: a template example that begins
# with a conventional-commit prefix still matches when echoed.
cat > "$prompts/cc.md" <<'EOF'
---
tier: prose
---
# cc

## When to use
n/a

## Prompt template

```
Write a commit message.

Correct: fix: bump the model-resolution cache TTL to 60 seconds flat

=== Facts ===
{{stdin}}
```

## Calibration notes
n/a
EOF
make_mock_curl_think "$tmp" 'fix: bump the model-resolution cache TTL to 60 seconds flat'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cc prose "go" 2>&1)
assert_contains "check 'no_example_echo' FAILED" "$out" \
  "echo-check: echoed template example beginning with a type prefix is caught"
# 40c. A genuine answer must not trip it.
make_mock_curl_think "$tmp" 'The override in src/config/loader.js:88 silently wins. Could you make it defer?'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-check: genuine answer must not trip the check"; fail=$((fail+1))
else
  echo "  PASS  echo-check: genuine answer does not trip the check"; pass=$((pass+1))
fi
# 40c-ii. The failure names exemplar boilerplate as a cause: with one
# exemplar the check cannot tell a footer from content, and the fix belongs
# in the exemplar.
make_mock_curl_think "$tmp" 'The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
assert_contains "strip it from" "$out" \
  "echo-check: the failure says to strip boilerplate from the exemplar"
assert_contains "pass two" "$out" \
  "echo-check: the failure says why one exemplar cannot be classified"

# 40d. Short shared lines are below the 40-char floor, so a recipe and its
# output can share a heading or a sign-off without colliding.
make_mock_curl_think "$tmp" '=== Facts ==='
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-check: short shared line must stay below the length floor"; fail=$((fail+1))
else
  echo "  PASS  echo-check: short shared line stays below the length floor"; pass=$((pass+1))
fi
# 40e. The comparison runs against the pre-substitution template, so
# reproducing a piped fact never flags.
make_mock_curl_think "$tmp" 'The token drop is on the Teams side, inside its own MSAL cache layer.'
out=$(echo "The token drop is on the Teams side, inside its own MSAL cache layer." \
  | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-check: reproducing piped context must not flag"; fail=$((fail+1))
else
  echo "  PASS  echo-check: reproducing piped context does not flag"; pass=$((pass+1))
fi
# 40f. Env opt-out.
make_mock_curl_think "$tmp" 'The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_ECHO_CHECK=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe anchor prose "go" 2>&1)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-check: DELEGATE_NO_ECHO_CHECK=1 must silence it"; fail=$((fail+1))
else
  echo "  PASS  echo-check: DELEGATE_NO_ECHO_CHECK=1 silences it"; pass=$((pass+1))
fi
# 40g. Frontmatter opt-out is silent and not reported as an unknown check.
cat > "$prompts/optout.md" <<'EOF'
---
tier: prose
checks:
  no_example_echo: false
---
# optout

## When to use
n/a

## Prompt template

```
Answer using only the facts below.

Correct: The regression is in the date parser. Could you confirm whether it also happens on older inputs?

=== Facts ===
{{stdin}}
```

## Calibration notes
n/a
EOF
out=$(echo "facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe optout prose "go" 2>&1)
if [[ "$out" == *"no_example_echo"* || "$out" == *"unknown check"* ]]; then
  echo "  FAIL  echo-check: frontmatter opt-out must be silent and known"; fail=$((fail+1))
else
  echo "  PASS  echo-check: frontmatter opt-out is silent and recognised"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 40h. echo_guard_vars (#428): a recipe declares which --var values are
# shape anchors, and their lines join the forbidden-output set ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/cm.md" <<'EOF'
---
tier: prose
inputs:
  recent_commits: string
  why: string
echo_guard_vars: recent_commits
---
# cm

## When to use
Exemplar-echo test recipe.

## Prompt template

```
Write a commit message.

=== Recent commits (SHAPE anchors) ===
{{recent_commits}}

=== Why ===
{{why}}
```

## Calibration notes
n/a
EOF
ANCHORS='chore(deps): bump codeql-action init and analyze together to v4.37.6 (#253)
chore(deps): bump github/codeql-action/analyze from 4.37.3 to 4.37.4 (#240)
perf(football): cut CI validate from 34 to 7 minutes (#287)'
run_cm() {
  echo x | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe cm --var recent_commits="$ANCHORS" --var why="w" 2>&1 >/dev/null
}
# 40h-i. Type prefix and PR suffix are stripped from both sides, so an
# anchor echoed under a different prefix is caught.
make_mock_curl_think "$tmp" 'ci: bump codeql-action init and analyze together to v4.37.6\n\nCombines the Dependabot PRs.'
out=$(run_cm)
assert_contains "check 'no_example_echo' FAILED" "$out" \
  "echo-guard: anchor subject echoed under a different type prefix is caught"
assert_contains '"checks_failed_names":["no_example_echo"]' "$(tail -1 "$metrics")" \
  "echo-guard: named on the metrics row"
# 40h-ii. An exact copy including the PR suffix is caught too.
make_mock_curl_think "$tmp" 'chore(deps): bump codeql-action init and analyze together to v4.37.6 (#253)\n\nbody here.'
assert_contains "check 'no_example_echo' FAILED" "$(run_cm)" \
  "echo-guard: verbatim anchor including its PR suffix is caught"
# 40h-iii. A correct subject that shares vocabulary with the anchors must not flag.
make_mock_curl_think "$tmp" 'chore(deps): bump codeql-action to v4.37.8 and osv-scanner-action to v2.5.1\n\nCombines four Dependabot PRs that each touch one workflow file.'
out=$(run_cm)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-guard: the correct subject for the same change must not flag"; fail=$((fail+1))
else
  echo "  PASS  echo-guard: the correct subject for the same change does not flag"; pass=$((pass+1))
fi
# 40h-iv. A line repeated across anchors is convention the output should
# reproduce, so it is dropped from the pattern set.
BOILER='chore(deps): bump one thing to v1 (#1)

Generated with the standard project tooling and reviewed by a maintainer.

chore(deps): bump another thing to v2 (#2)

Generated with the standard project tooling and reviewed by a maintainer.'
make_mock_curl_think "$tmp" 'feat: a brand new and entirely different subject line\n\nGenerated with the standard project tooling and reviewed by a maintainer.'
out=$(echo x | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cm --var recent_commits="$BOILER" --var why="w" 2>&1 >/dev/null)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-guard: a line repeated across anchors must not be forbidden"; fail=$((fail+1))
else
  echo "  PASS  echo-guard: a line repeated across anchors is convention, not flagged"; pass=$((pass+1))
fi
# 40h-v. Without the declaration the vars are ordinary content: the guard is opt-in.
sed '/^echo_guard_vars:/d' "$prompts/cm.md" > "$prompts/cm2.md"
make_mock_curl_think "$tmp" 'ci: bump codeql-action init and analyze together to v4.37.6\n\nCombines the Dependabot PRs.'
out=$(echo x | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cm2 --var recent_commits="$ANCHORS" --var why="w" 2>&1 >/dev/null)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-guard: must stay opt-in via echo_guard_vars"; fail=$((fail+1))
else
  echo "  PASS  echo-guard: undeclared vars are not guarded (opt-in)"; pass=$((pass+1))
fi
# 40h-vi. `echo_guard_vars: a, b` with a space after the comma: an `IFS=,
# read` refactor would leave the second name with a leading space.
cat > "$prompts/two.md" <<'EOF'
---
tier: prose
inputs:
  aa: string
  bb: string
echo_guard_vars: aa, bb
---
# two

## When to use
n/a

## Prompt template

```
Write something.
{{aa}}
{{bb}}
```

## Calibration notes
n/a
EOF
make_mock_curl_think "$tmp" 'the second exemplar line which is definitely over forty characters'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe two \
    --var aa="the first exemplar line which is definitely over forty characters" \
    --var bb="the second exemplar line which is definitely over forty characters" \
    </dev/null 2>&1 >/dev/null)
assert_contains "check 'no_example_echo' FAILED" "$out" \
  "echo-guard: a var listed after 'comma space' is still guarded"
# 40h-vii. Convention is judged on the normalised form: two anchors that
# differ only by prefix and PR suffix are one repeated line.
VARIANTS='chore(deps): bump the shared tooling image to the newest tag (#1)

ci: bump the shared tooling image to the newest tag (#2)'
make_mock_curl_think "$tmp" 'feat: bump the shared tooling image to the newest tag\n\nbody.'
out=$(echo x | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cm --var recent_commits="$VARIANTS" --var why="w" 2>&1 >/dev/null)
if [[ "$out" == *"no_example_echo"* ]]; then
  echo "  FAIL  echo-guard: prefix-variant lines shared across anchors are convention"; fail=$((fail+1))
else
  echo "  PASS  echo-guard: prefix-variant lines shared across anchors are convention"; pass=$((pass+1))
fi
# 40h-viii. Each side is normalised exactly once: echo_normalise strips one
# type prefix per pass, so a doubled-prefix anchor normalised twice would no
# longer match its own echo.
DOUBLED='chore: fix: update the dependency pin to the newest release (#9)

perf(football): cut CI validate from 34 to 7 minutes (#287)'
make_mock_curl_think "$tmp" 'chore: fix: update the dependency pin to the newest release (#9)\n\nbody.'
out=$(echo x | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cm --var recent_commits="$DOUBLED" --var why="w" 2>&1 >/dev/null)
assert_contains "check 'no_example_echo' FAILED" "$out" \
  "echo-guard: an anchor with a doubled type prefix echoed verbatim is caught"
rm -rf "$tmp" "$metrics"

# --- 41. Draft capture: the output is persisted beside its metrics row so a
# later MISS carries the artefact ---
tmp=$(mktemp -d)
data="$tmp/data"; mkdir -p "$data"
metrics="$data/metrics.jsonl"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/cap.md" <<'EOF'
---
tier: prose
---
# cap

## When to use
n/a

## Prompt template

```
GO
{{stdin}}
```

## Calibration notes
n/a
EOF
make_mock_curl_think "$tmp" 'a draft worth keeping around'
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
if [[ -n "$draft_name" && -f "$data/drafts/$draft_name" ]]; then
  echo "  PASS  draft-capture: draft_file names a file that exists"; pass=$((pass+1))
else
  echo "  FAIL  draft-capture: draft_file missing or file absent (got '$draft_name')"; fail=$((fail+1))
fi
assert_eq "a draft worth keeping around" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: file holds the generated output verbatim"
# The name leads with the row ts and carries a suffix, since ts alone is
# second-precision and parallel delegations share it.
row_ts=$(printf '%s' "$row" | jq -r '.ts')
case "$draft_name" in
  "$(printf '%s' "$row_ts" | tr -d ':-')"-*.draft.txt)
    echo "  PASS  draft-capture: filename leads with the row ts and is suffixed"; pass=$((pass+1)) ;;
  *) echo "  FAIL  draft-capture: unexpected draft filename '$draft_name'"; fail=$((fail+1)) ;;
esac
# 41a-i. Two delegations in the same second must not clobber each other.
# Drafts only: a recipe call also stores its input beside each draft (#516).
before_count=$(ls "$data/drafts" | grep -c '\.draft\.txt$')
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
after_count=$(ls "$data/drafts" | grep -c '\.draft\.txt$')
if (( after_count == before_count + 2 )); then
  echo "  PASS  draft-capture: two same-second delegations write two distinct files"; pass=$((pass+1))
else
  echo "  FAIL  draft-capture: same-second delegations collided ($before_count -> $after_count)"; fail=$((fail+1))
fi
missing=0
while IFS= read -r df; do
  [[ -z "$df" ]] && continue
  [[ -f "$data/drafts/$df" ]] || missing=$((missing+1))
done < <(jq -r '.draft_file // empty' "$metrics")
assert_eq 0 "$missing" "draft-capture: every draft_file on a row exists on disk"
# 41a-ii. Drafts hold piped context, so directory and files must not inherit
# a permissive umask; only a wide-open umask makes the bug visible.
rm -rf "$data"; mkdir -p "$data"
( umask 000
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1 )
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_eq "700" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$data/drafts")" \
  "draft-capture: drafts directory is private (700) under a permissive umask"
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$data/drafts/$draft_name")" \
  "draft-capture: draft file is private (600) under a permissive umask"
# 41b. Opt-out.
rm -rf "$data"; mkdir -p "$data"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_DRAFT_CAPTURE=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
assert_eq "false" "$(tail -1 "$metrics" | jq -r 'has("draft_file")')" \
  "draft-capture: DELEGATE_NO_DRAFT_CAPTURE=1 writes no draft_file field"
assert_eq "false" "$(tail -1 "$metrics" | jq -r 'has("input_file")')" \
  "draft-capture: DELEGATE_NO_DRAFT_CAPTURE=1 writes no input_file field either"
if [[ -d "$data/drafts" ]]; then
  echo "  FAIL  draft-capture: opt-out must not create the drafts directory"; fail=$((fail+1))
else
  echo "  PASS  draft-capture: opt-out creates no drafts directory"; pass=$((pass+1))
fi
# 41c. Metrics off means no row to join to, so no draft either.
rm -rf "$data"; mkdir -p "$data"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
if [[ -d "$data/drafts" ]]; then
  echo "  FAIL  draft-capture: NO_METRICS must not capture a draft"; fail=$((fail+1))
else
  echo "  PASS  draft-capture: NO_METRICS captures no draft"; pass=$((pass+1))
fi
# 41d. Oversized output is truncated with a marker rather than dropped.
rm -rf "$data"; mkdir -p "$data"
make_mock_curl_think "$tmp" 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_DRAFT_MAX_BYTES=20 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_contains "[truncated at 20 bytes" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: oversized draft is truncated with a marker"
# 41e. The cap is in bytes: eight 3-byte characters are 24 bytes. LANG is
# set because under `env -i` (C locale) bash counts bytes anyway.
rm -rf "$data"; mkdir -p "$data"
make_mock_curl_think "$tmp" '\u4e2d\u6587\u6d4b\u8bd5\u4e2d\u6587\u6d4b\u8bd5'
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" LANG=en_US.UTF-8 DELEGATE_DRAFT_MAX_BYTES=20 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null >/dev/null 2>&1
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_contains "[truncated at 20 bytes" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: byte cap measured in bytes, not characters"
# 41f. A malformed cap falls back to the default.
rm -rf "$data"; mkdir -p "$data"
make_mock_curl_think "$tmp" 'short'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_DRAFT_MAX_BYTES=abc \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cap prose "go" </dev/null 2>&1)
assert_contains "is not a positive integer" "$out" "draft-capture: malformed byte cap is reported"
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_eq "short" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: malformed byte cap still captures under the default bound"
# 41g. The rendered input the model saw is stored beside the draft under the
# same stem and named on the row (#516), so the calibration loop can score the
# pair against the supplied facts without the caller re-supplying them.
rm -rf "$data"; mkdir -p "$data"
cat > "$prompts/capin.md" <<'EOF'
---
tier: prose
---
# capin

## When to use
n/a

## Prompt template

```
RENDERED-TEMPLATE-MARKER
Facts:
{{stdin}}
```

## Calibration notes
n/a
EOF
make_mock_curl_think "$tmp" 'a draft worth keeping around'
( umask 000
  printf 'the distinctive piped fact about widget-7\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe capin prose "go" >/dev/null 2>&1 )
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
input_name=$(printf '%s' "$row" | jq -r '.input_file // ""')
assert_eq "${draft_name%.draft.txt}.input.txt" "$input_name" \
  "input-capture: input_file shares the draft's stem"
if [[ -n "$input_name" && -f "$data/drafts/$draft_name" && -f "$data/drafts/$input_name" ]]; then
  echo "  PASS  input-capture: draft and input both exist on disk"; pass=$((pass+1))
else
  echo "  FAIL  input-capture: draft or input missing (draft='$draft_name' input='$input_name')"; fail=$((fail+1))
fi
input_body=$(cat "$data/drafts/$input_name" 2>/dev/null)
assert_contains "RENDERED-TEMPLATE-MARKER" "$input_body" "input-capture: file holds the recipe template"
assert_contains "the distinctive piped fact about widget-7" "$input_body" \
  "input-capture: file holds the piped context, substituted for {{stdin}}"
assert_eq $'RENDERED-TEMPLATE-MARKER\nFacts:\nthe distinctive piped fact about widget-7\n\ngo' "$input_body" \
  "input-capture: file is exactly the rendered prompt the model was sent"
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$data/drafts/$input_name")" \
  "input-capture: input file is private (600) under a permissive umask"
# 41g-i. A bare call is unchanged: the draft alone, no input file, no field.
printf 'bare piped context\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
assert_eq "true" "$(printf '%s' "$row" | jq -r 'has("draft_file")')" \
  "input-capture: a bare call still captures its draft"
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("input_file")')" \
  "input-capture: a bare call writes no input_file field"
if [[ -n "$draft_name" && ! -e "$data/drafts/${draft_name%.draft.txt}.input.txt" ]]; then
  echo "  PASS  input-capture: a bare call writes no input file"; pass=$((pass+1))
else
  echo "  FAIL  input-capture: a bare call wrote an input file beside '$draft_name'"; fail=$((fail+1))
fi
# 41g-ii. Retention prunes the input with the draft it belongs to.
old_stem="20200101T000000Z-deadbeef"
printf 'old' > "$data/drafts/$old_stem.draft.txt"
printf 'old' > "$data/drafts/$old_stem.input.txt"
touch -t 202001010000 "$data/drafts/$old_stem.draft.txt" "$data/drafts/$old_stem.input.txt"
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_DRAFT_RETENTION_DAYS=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capin prose "go" >/dev/null 2>&1
if [[ ! -e "$data/drafts/$old_stem.draft.txt" && ! -e "$data/drafts/$old_stem.input.txt" ]]; then
  echo "  PASS  input-capture: retention removes the expired draft and its input"; pass=$((pass+1))
else
  echo "  FAIL  input-capture: retention left $(ls "$data/drafts" | grep -c "^$old_stem") expired file(s)"; fail=$((fail+1))
fi
# 41h. The structured inputs — piped stdin, every --var as passed, the
# positional prompt — are stored as JSON under the same stem and named on the
# row as inputs_file, and the row carries the template's content hash, so
# replay-recipe.sh can render the same case under another template and the
# outcomes before and after an edit can be told apart.
rm -rf "$data"; mkdir -p "$data"
cat > "$prompts/capvar.md" <<'EOF'
---
tier: prose
inputs:
  stdin: string
  who: string
  note: string?
---
# capvar

## When to use
n/a

## Prompt template

```
To {{who}}:
{{stdin}}
Note: {{note}}
```

## Calibration notes
n/a
EOF
make_mock_curl_think "$tmp" 'a draft'
printf 'fact one about widget-7\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=alice --var "note=$(printf 'two\nlines')" prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
inputs_name=$(printf '%s' "$row" | jq -r '.inputs_file // ""')
assert_eq "${draft_name%.draft.txt}.inputs.json" "$inputs_name" \
  "inputs-capture: inputs_file shares the draft's stem"
inputs_path="$data/drafts/$inputs_name"
if [[ -n "$inputs_name" && -f "$inputs_path" ]]; then
  echo "  PASS  inputs-capture: the inputs file exists on disk"; pass=$((pass+1))
else
  echo "  FAIL  inputs-capture: inputs file missing (inputs='$inputs_name')"; fail=$((fail+1))
fi
assert_eq "capvar" "$(jq -r '.recipe' "$inputs_path" 2>/dev/null)" "inputs-capture: file names the recipe"
assert_eq "fact one about widget-7" "$(jq -r '.stdin' "$inputs_path" 2>/dev/null)" \
  "inputs-capture: file holds the piped stdin"
assert_eq "alice" "$(jq -r '.vars.who' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds each --var by key"
assert_eq $'two\nlines' "$(jq -r '.vars.note' "$inputs_path" 2>/dev/null)" \
  "inputs-capture: a --var value keeps its newline"
assert_eq "go" "$(jq -r '.prompt' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds the positional prompt"
assert_eq "prose" "$(jq -r '.tier' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds the resolved tier"
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$inputs_path")" \
  "inputs-capture: inputs file is private (600)"
# The hash covers the frontmatter and the prompt block, the parts that shape
# the output, and is computed by the helper both scripts share.
. "$REPO/scripts/lib/recipe.sh"
expected_sha=$(recipe_template_sha "$prompts/capvar.md")
assert_eq "$expected_sha" "$(printf '%s' "$row" | jq -r '.template_sha // ""')" \
  "template-sha: the row carries the 12-char hash of the recipe's frontmatter and prompt block"
if [[ "$expected_sha" =~ ^[0-9a-f]{12}$ ]]; then
  echo "  PASS  template-sha: the hash is 12 hex characters"; pass=$((pass+1))
else
  echo "  FAIL  template-sha: unexpected hash '$expected_sha'"; fail=$((fail+1))
fi
# A key passed twice keeps its first value in the inputs, because that is
# the value the substitution used.
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=alice --var who=bob prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
dup_inputs="$data/drafts/$(printf '%s' "$row" | jq -r '.inputs_file // ""')"
dup_input="$data/drafts/$(printf '%s' "$row" | jq -r '.input_file // ""')"
assert_contains "To alice:" "$(cat "$dup_input" 2>/dev/null)" \
  "inputs-capture: a --var passed twice is rendered with its first value"
assert_eq "alice" "$(jq -r '.vars.who' "$dup_inputs" 2>/dev/null)" \
  "inputs-capture: a --var passed twice is recorded with its first value"
# A calibration note does not change the hash; an edit to the prompt block does.
printf '\n- 2026-09-19: a dated note, prose only\n' >> "$prompts/capvar.md"
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=dora prose "go" >/dev/null 2>&1
assert_eq "$expected_sha" "$(tail -1 "$metrics" | jq -r '.template_sha // ""')" \
  "template-sha: a calibration-notes edit keeps the hash"
sed -i.bak 's/^To {{who}}:$/Dear {{who}}:/' "$prompts/capvar.md" && rm -f "$prompts/capvar.md.bak"
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=erin prose "go" >/dev/null 2>&1
edited_sha=$(tail -1 "$metrics" | jq -r '.template_sha // ""')
if [[ -n "$edited_sha" && "$edited_sha" != "$expected_sha" ]]; then
  echo "  PASS  template-sha: a prompt-block edit changes the hash"; pass=$((pass+1))
else
  echo "  FAIL  template-sha: prompt-block edit left the hash at '$edited_sha'"; fail=$((fail+1))
fi
# Over the byte cap the JSON is not written at all: a cut JSON is unreadable.
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_DRAFT_MAX_BYTES=40 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=frank prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
assert_eq "true" "$(printf '%s' "$row" | jq -r 'has("draft_file")')" \
  "inputs-capture: over the cap the draft is still captured (truncated)"
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("inputs_file")')" \
  "inputs-capture: over the cap no inputs file is written and no field names one"
# The draft alone can be switched off and the hash still lands: it is on
# the row, not in a file.
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_DRAFT_CAPTURE=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=bob prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("inputs_file")')" \
  "inputs-capture: DELEGATE_NO_DRAFT_CAPTURE=1 writes no inputs_file field"
# Against the file as it now stands: the prompt-block edit above changed it.
assert_eq "$(recipe_template_sha "$prompts/capvar.md")" "$(printf '%s' "$row" | jq -r '.template_sha // ""')" \
  "template-sha: recorded even when the draft capture is off"
# A bare call has no template to hash and no recipe to replay.
printf 'bare piped context\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("inputs_file")')" \
  "inputs-capture: a bare call writes no inputs_file field"
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("template_sha")')" \
  "template-sha: a bare call carries no template_sha"
# Retention prunes the structured inputs with the draft they belong to.
old_stem="20200101T000000Z-deadbeef"
printf 'old' > "$data/drafts/$old_stem.draft.txt"
printf '{}' > "$data/drafts/$old_stem.inputs.json"
touch -t 202001010000 "$data/drafts/$old_stem.draft.txt" "$data/drafts/$old_stem.inputs.json"
printf 'ctx\n' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_DRAFT_RETENTION_DAYS=1 \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe capvar --var who=carol prose "go" >/dev/null 2>&1
if [[ ! -e "$data/drafts/$old_stem.draft.txt" && ! -e "$data/drafts/$old_stem.inputs.json" ]]; then
  echo "  PASS  inputs-capture: retention removes the expired inputs file with its draft"; pass=$((pass+1))
else
  echo "  FAIL  inputs-capture: retention left $(ls "$data/drafts" | grep -c "^$old_stem") expired file(s)"; fail=$((fail+1))
fi
rm -rf "$tmp" "$data"

# --- 42. body_max_words: the body is everything after the first blank line;
# the limit can come from the flavor profile ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/bw.md" <<'EOF'
---
tier: prose
checks:
  body_max_words: 10
---
# bw

## When to use
n/a

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
run_bw() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe bw prose "go" </dev/null 2>&1 >/dev/null
}
# 42a. Over the limit fails and is named on the row.
make_mock_curl_think "$tmp" 'subject here\n\none two three four five six seven eight nine ten eleven twelve'
out=$(run_bw)
assert_contains "check 'body_max_words' FAILED — body is 12 words (> 10)" "$out" \
  "body_max_words: over-limit body fails with both counts named"
assert_contains '"checks_failed_names":["body_max_words"]' "$(tail -1 "$metrics")" \
  "body_max_words: named on the metrics row"
# 42b. At the limit passes — the comparison is >, not >=.
make_mock_curl_think "$tmp" 'subject here\n\none two three four five six seven eight nine ten'
if [[ "$(run_bw)" == *"body_max_words"* ]]; then
  echo "  FAIL  body_max_words: a body exactly at the limit must pass"; fail=$((fail+1))
else
  echo "  PASS  body_max_words: a body exactly at the limit passes"; pass=$((pass+1))
fi
# 42c. The subject is not part of the body.
make_mock_curl_think "$tmp" 'a very long subject line with many many many many words indeed\n\ntwo words'
if [[ "$(run_bw)" == *"body_max_words"* ]]; then
  echo "  FAIL  body_max_words: the subject line must not be counted"; fail=$((fail+1))
else
  echo "  PASS  body_max_words: the subject line is not counted"; pass=$((pass+1))
fi
# 42d. A subject-only message is body_required's business, not this check's.
make_mock_curl_think "$tmp" 'subject here'
if [[ "$(run_bw)" == *"body_max_words"* ]]; then
  echo "  FAIL  body_max_words: subject-only output is body_required's business"; fail=$((fail+1))
else
  echo "  PASS  body_max_words: subject-only output is left to body_required"; pass=$((pass+1))
fi
# 42e. Paragraphs are summed: six words each, neither over the limit alone.
make_mock_curl_think "$tmp" 'subject\n\none two three four five six\n\nseven eight nine ten eleven twelve'
assert_contains "body is 12 words" "$(run_bw)" \
  "body_max_words: paragraphs after the first blank line are summed"
# 42e-i. CRLF measures the same as LF: an awk that does not treat a lone \r
# as [[:space:]] (mawk on CI, not BWK awk on macOS) would never find the separator.
make_mock_curl_think "$tmp" 'subject here\r\n\r\none two three four five six seven eight nine ten eleven twelve'
assert_contains "body is 12 words (> 10)" "$(run_bw)" \
  "body_max_words: CRLF output measures the same as LF"
# 42f. The limit can come from the flavor profile.
cat > "$prompts/bwf.md" <<'EOF'
---
tier: prose
checks:
  body_max_words: {{flavor_commit_body_max_words}}
---
# bwf

## When to use
n/a

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
prof="$tmp/profile.sh"
printf 'FLAVOR_COMMIT_BODY_MAX_WORDS=3\n' > "$prof"
chmod 600 "$prof"
make_mock_curl_think "$tmp" 'subject\n\none two three four five'
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_LOCAL_PROFILE="$prof" \
  bash "$SCRIPT" --recipe bwf prose "go" </dev/null 2>&1 >/dev/null)
assert_contains "body is 5 words (> 3)" "$out" \
  "body_max_words: the limit comes from the flavor profile"
rm -rf "$tmp" "$metrics"

# --- 43. no_single_item_list: a numbered list holding exactly one item is
# wrong on every branch of the reply recipes (one ask is a sentence) ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
mk_sil_recipe() {
  cat > "$prompts/sil.md" <<EOF
---
tier: prose
checks:
  no_single_item_list: $1
---
# sil

## When to use
n/a

## Prompt template

\`\`\`
GO
\`\`\`

## Calibration notes
n/a
EOF
}
run_sil() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe sil prose "go" </dev/null 2>&1 >/dev/null
}
mk_sil_recipe true
# 43a. One sentence of verdict, then a single numbered ask.
make_mock_curl_think "$tmp" '@swayamg20, the fix in sanitize_diagram() handles unquoted labels.\n1. Would you like to apply the two inline suggestions, or leave the pipe-label case for a follow-up?'
out=$(run_sil)
assert_contains "check 'no_single_item_list' FAILED" "$out" \
  "no_single_item_list: a one-item numbered list fails"
assert_contains '"checks_failed_names":["no_single_item_list"]' "$(tail -1 "$metrics")" \
  "no_single_item_list: named on the metrics row"
# 43b. Two items is the legitimate multi-ask shape.
make_mock_curl_think "$tmp" 'The cause is the flag flip.\n1. Does it reproduce on 2.9?\n2. Could you paste the launch flags?'
if [[ "$(run_sil)" == *"no_single_item_list"* ]]; then
  echo "  FAIL  no_single_item_list: a genuine two-ask list must pass"; fail=$((fail+1))
else
  echo "  PASS  no_single_item_list: a genuine two-ask list passes"; pass=$((pass+1))
fi
# 43c. Plain prose has no list at all and must pass.
make_mock_curl_think "$tmp" 'The cause is the flag flip. Could you confirm whether it survives a cold start?'
if [[ "$(run_sil)" == *"no_single_item_list"* ]]; then
  echo "  FAIL  no_single_item_list: prose with no list must pass"; fail=$((fail+1))
else
  echo "  PASS  no_single_item_list: prose with no list passes"; pass=$((pass+1))
fi
# 43d. The paren form of the enumerator counts too.
make_mock_curl_think "$tmp" 'The cause is the flag flip.\n1) Could you paste the launch flags?'
assert_contains "check 'no_single_item_list' FAILED" "$(run_sil)" \
  "no_single_item_list: the 1) enumerator form counts"
# 43e. An enumerator needs its trailing space: a decimal opening a wrapped
# line is not a list item.
make_mock_curl_think "$tmp" 'The regression landed in\n2.9.1 and not before it.'
if [[ "$(run_sil)" == *"no_single_item_list"* ]]; then
  echo "  FAIL  no_single_item_list: a bare decimal is not a list item"; fail=$((fail+1))
else
  echo "  PASS  no_single_item_list: a bare decimal is not a list item"; pass=$((pass+1))
fi
# 43f. CRLF behaves the same as LF (a lone \r is non-whitespace to some awks).
make_mock_curl_think "$tmp" 'The cause is the flag flip.\r\n1. Could you paste the launch flags?'
assert_contains "check 'no_single_item_list' FAILED" "$(run_sil)" \
  "no_single_item_list: CRLF output behaves the same as LF"
# 43g. A `false` value skips the check without an unknown-check warning.
mk_sil_recipe false
make_mock_curl_think "$tmp" 'The cause is the flag flip.\n1. Could you paste the launch flags?'
out=$(run_sil)
if [[ "$out" == *"no_single_item_list' FAILED"* || "$out" == *"unknown check"* ]]; then
  echo "  FAIL  no_single_item_list: 'false' must skip the check quietly"; fail=$((fail+1))
else
  echo "  PASS  no_single_item_list: 'false' skips the check quietly"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 44. no_invented_task_list: fires only when the output has a task list
# and the --var named in the frontmatter (the shape authority) has none, since
# a category box is correct output for a repo whose PR template asks for one ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
mk_tl_recipe() {
  cat > "$prompts/tl.md" <<EOF
---
tier: prose
checks:
  no_invented_task_list: $1
---
# tl

## When to use
n/a

## Prompt template

\`\`\`
Examples: {{examples}}
\`\`\`

## Calibration notes
n/a
EOF
}
run_tl() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_NO_ECHO_CHECK=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe tl --var examples="$1" prose "go" </dev/null 2>&1 >/dev/null
}
mk_tl_recipe examples
# 44a. An unchecked `## Test plan` appended to a body the examples never showed one for.
make_mock_curl_think "$tmp" 'Suites: 366 passed, 94/94.\n\n## Test plan\n- [ ] Run the prompts suite (not run yet)\n- [ ] Run the unit suite (not run yet)'
out=$(run_tl $'TITLE: a merged PR\nBODY:\nTwo sentences of prose. No checklist.')
assert_contains "check 'no_invented_task_list' FAILED" "$out" \
  "no_invented_task_list: an invented task list fails"
assert_contains "carries 2 markdown task-list item(s)" "$out" \
  "no_invented_task_list: the count is named"
assert_contains '"checks_failed_names":["no_invented_task_list"]' "$(tail -1 "$metrics")" \
  "no_invented_task_list: named on the metrics row"
# 44b. When the examples carry a checklist the output is matching its shape.
if [[ "$(run_tl $'TITLE: a merged PR\nBODY:\n## Type of change\n- [x] Bug fix\n- [ ] New feature')" == *"no_invented_task_list"* ]]; then
  echo "  FAIL  no_invented_task_list: a task list the examples also carry must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_task_list: a task list the examples also carry passes"; pass=$((pass+1))
fi
# 44c. No task list in the output at all.
make_mock_curl_think "$tmp" 'Two sentences of prose describing the change.\n\nRefs: AI-100'
if [[ "$(run_tl $'TITLE: a merged PR\nBODY:\nprose')" == *"no_invented_task_list"* ]]; then
  echo "  FAIL  no_invented_task_list: output with no task list must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_task_list: output with no task list passes"; pass=$((pass+1))
fi
# 44d. A ticked box counts the same as an unchecked one.
make_mock_curl_think "$tmp" 'Body.\n\n- [x] Tests pass'
assert_contains "check 'no_invented_task_list' FAILED" "$(run_tl $'TITLE: x\nBODY:\nprose')" \
  "no_invented_task_list: a ticked box counts too"
# 44e. Markdown allows *, + and - as list markers, and indented items.
make_mock_curl_think "$tmp" 'Body.\n\n  * [ ] one\n  + [ ] two'
assert_contains "carries 2 markdown task-list item(s)" "$(run_tl $'TITLE: x\nBODY:\nprose')" \
  "no_invented_task_list: * and + markers and indentation count"
# 44f. A bracketed word is not a checkbox.
make_mock_curl_think "$tmp" 'Body.\n\n- [draft] not a checkbox\n- [WIP] also not'
if [[ "$(run_tl $'TITLE: x\nBODY:\nprose')" == *"no_invented_task_list"* ]]; then
  echo "  FAIL  no_invented_task_list: a bracketed word is not a checkbox"; fail=$((fail+1))
else
  echo "  PASS  no_invented_task_list: a bracketed word is not a checkbox"; pass=$((pass+1))
fi
# 44g. An empty value skips the check without an unknown-check warning.
mk_tl_recipe ""
make_mock_curl_think "$tmp" 'Body.\n\n- [ ] one'
out=$(run_tl $'TITLE: x\nBODY:\nprose')
if [[ "$out" == *"no_invented_task_list' FAILED"* || "$out" == *"unknown check"* ]]; then
  echo "  FAIL  no_invented_task_list: an empty value must be inert and quiet"; fail=$((fail+1))
else
  echo "  PASS  no_invented_task_list: an empty value is inert and quiet"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 45. no_invented_refs: a trailer identifier must appear in the caller's
# --var values or piped context; the recipe template is excluded on purpose,
# because a Wrong example carrying a literal identifier gets copied (45d) ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/rf.md" <<'EOF'
---
tier: prose
checks:
  no_invented_refs: true
---
# rf

## When to use
n/a

## Prompt template

```
Examples: {{examples}}
Never continue a numbering sequence. Wrong: Refs: ZZ-9915
```

## Calibration notes
n/a
EOF
run_rf() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_NO_ECHO_CHECK=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe rf --var examples="$1" prose "go" </dev/null 2>&1 >/dev/null
}
# 45a. The examples end in AI-812 / AI-806 and the model continues the sequence.
make_mock_curl_think "$tmp" 'A short body describing the change.\n\nRefs: AI-813'
out=$(run_rf $'TITLE: one\nBODY:\nprose\nRefs: AI-812\n\nTITLE: two\nBODY:\nprose\nRefs: AI-806')
assert_contains "check 'no_invented_refs' FAILED" "$out" \
  "no_invented_refs: an ungrounded trailer identifier fails"
assert_contains "trailer names AI-813" "$out" \
  "no_invented_refs: the invented identifier is named"
assert_contains '"checks_failed_names":["no_invented_refs"]' "$(tail -1 "$metrics")" \
  "no_invented_refs: named on the metrics row"
# 45b. The same identifier, this time supplied by the caller. Must pass.
if [[ "$(run_rf $'TITLE: one\nBODY:\nprose for AI-813\nRefs: AI-813')" == *"no_invented_refs"* ]]; then
  echo "  FAIL  no_invented_refs: an identifier the caller supplied must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_refs: an identifier the caller supplied passes"; pass=$((pass+1))
fi
# 45c. Issue-number references are grounded the same way.
make_mock_curl_think "$tmp" 'A short body.\n\nCloses: #4271'
assert_contains "trailer names #4271" "$(run_rf $'TITLE: one\nBODY:\nprose\nCloses: #12')" \
  "no_invented_refs: an ungrounded issue number fails"
# 45d. An identifier that appears only in the recipe's own Wrong example is
# not grounded.
make_mock_curl_think "$tmp" 'A short body.\n\nRefs: ZZ-9915'
assert_contains "trailer names ZZ-9915" "$(run_rf $'TITLE: one\nBODY:\nprose\nRefs: AI-812')" \
  "no_invented_refs: an identifier taken from the recipe's own text is not grounded"
# 45d-i. Grounding is token-for-token, not substring: `#4271` does not ground `#427`.
make_mock_curl_think "$tmp" 'A short body.\n\nCloses: #427'
assert_contains "trailer names #427" "$(run_rf $'TITLE: one\nBODY:\nfixes #4271 in the parser')" \
  "no_invented_refs: a prefix of a grounded identifier is not itself grounded"
# 45e. Only trailer-shaped lines are scanned, not prose.
make_mock_curl_think "$tmp" 'The parser now reads UTF-8 and rejects ISO-8859 input, per RFC-3629.'
if [[ "$(run_rf $'TITLE: one\nBODY:\nprose')" == *"no_invented_refs"* ]]; then
  echo "  FAIL  no_invented_refs: hyphenated tokens in prose must not be scanned"; fail=$((fail+1))
else
  echo "  PASS  no_invented_refs: hyphenated tokens in prose are not scanned"; pass=$((pass+1))
fi
# 45f. A trailer with no identifier in it at all.
make_mock_curl_think "$tmp" 'A short body.\n\nSuites: 366 passed, 94/94'
if [[ "$(run_rf $'TITLE: one\nBODY:\nprose')" == *"no_invented_refs"* ]]; then
  echo "  FAIL  no_invented_refs: a trailer with no identifier must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_refs: a trailer with no identifier passes"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 46. Zero-padded numeric limits are decimal: bash reads a leading zero
# as octal, so `subject_max: 08` would abort the comparison and fail open ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
mk_oct_recipe() {
  cat > "$prompts/oct.md" <<EOF
---
tier: prose
checks:
  subject_max: $1
  body_max_words: $2
---
# oct

## When to use
n/a

## Prompt template

\`\`\`
GO
\`\`\`

## Calibration notes
n/a
EOF
}
run_oct() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_NO_ECHO_CHECK=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe oct prose "go" </dev/null 2>&1 >/dev/null
}
# 46a. A zero-padded subject limit still fires, and leaks no arithmetic error.
mk_oct_recipe 08 500
make_mock_curl_think "$tmp" 'a subject line that is definitely longer than eight characters'
out=$(run_oct)
assert_contains "check 'subject_max' FAILED" "$out" \
  "base-10: a zero-padded subject_max still fires"
if [[ "$out" == *"value too great for base"* ]]; then
  echo "  FAIL  base-10: subject_max must leak no arithmetic error"; fail=$((fail+1))
else
  echo "  PASS  base-10: subject_max leaks no arithmetic error"; pass=$((pass+1))
fi
# 46b. Same for the body word cap.
mk_oct_recipe 500 09
make_mock_curl_think "$tmp" 'subject\n\none two three four five six seven eight nine ten eleven twelve'
out=$(run_oct)
assert_contains "check 'body_max_words' FAILED — body is 12 words (> 09)" "$out" \
  "base-10: a zero-padded body_max_words still fires"
if [[ "$out" == *"value too great for base"* ]]; then
  echo "  FAIL  base-10: body_max_words must leak no arithmetic error"; fail=$((fail+1))
else
  echo "  PASS  base-10: body_max_words leaks no arithmetic error"; pass=$((pass+1))
fi
# 46c. A padded limit above the measured value still passes.
mk_oct_recipe 0500 0500
make_mock_curl_think "$tmp" 'short subject\n\ntwo words'
out=$(run_oct)
if [[ "$out" == *"FAILED"* || "$out" == *"value too great for base"* ]]; then
  echo "  FAIL  base-10: a padded limit above the measured value must pass"; fail=$((fail+1))
else
  echo "  PASS  base-10: a padded limit above the measured value passes"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 47. Retry on check failure (#384): exactly one more generation naming
# the failed check, never a loop ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/rt.md" <<'EOF'
---
tier: prose
checks:
  subject_max: 12
---
# rt

## When to use
n/a

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF

make_mock_curl_seq() {
  # Answers dispatches from a queue of canned contents, counting each in $2
  # (discovery is answered first and not counted) and saving the payload as
  # "$dir/payload.<n>.json". The last content repeats once the queue is
  # spent, so an unbounded retry shows as a count, not a hang.
  local dir="$1" counter="$2"; shift 2
  local q="$dir/queue"; : > "$q"
  local c
  for c in "$@"; do printf '%s\n' "$c" >> "$q"; done
  : > "$counter"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
out_file=""
write_out=""
saw_probe=0
argv_all="\$*"
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *"/v1/models"*) saw_probe=1; shift ;;
    *) shift ;;
  esac
done
if (( saw_probe == 1 )); then printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0; fi
echo x >> "$counter"
n=\$(wc -l < "$counter" | tr -d ' ')
cat > "$dir/payload.\$n.json"
line=\$(sed -n "\${n}p" "$q")
[[ -z "\$line" ]] && line=\$(tail -n 1 "$q")
body="{\"choices\":[{\"message\":{\"content\":\"\$line\"},\"finish_reason\":\"stop\"}]}"
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\{time_starttransfer\}/0.001}"
fi
EOF
  chmod +x "$dir/curl"
}
counter="$tmp/calls"
run_rt() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    ${1:+DELEGATE_NO_RETRY=1} \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe rt prose "go" </dev/null
}

# 47a. A failed check re-generates once and the second output is delivered.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" \
  'this subject line is far too long\n\nbody' \
  'short one\n\nbody'
out=$(run_rt 2>/dev/null)
assert_eq 2 "$(wc -l < "$counter" | tr -d ' ')" \
  "retry: a failed check costs exactly two dispatches"
assert_contains "short one" "$out" \
  "retry: the caller receives the retried output, not the rejected one"

# 47b. A first output that passes is never retried.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
out=$(run_rt 2>/dev/null)
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "retry: a passing check costs exactly one dispatch"

# 47c. The retry names the failed check.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" \
  'this subject line is far too long\n\nbody' \
  'short one\n\nbody'
run_rt >/dev/null 2>&1
assert_contains "subject_max" "$(cat "$tmp/payload.2.json")" \
  "retry: the second request names the check that failed"
if [[ "$(cat "$tmp/payload.1.json")" == *"was rejected"* ]]; then
  echo "  FAIL  retry: the FIRST request must not carry a rejection notice"; fail=$((fail+1))
else
  echo "  PASS  retry: the first request carries no rejection notice"; pass=$((pass+1))
fi

# 47d. One retry, never a loop: every response fails.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'this subject line is far too long\n\nbody'
EC=0
run_rt >/dev/null 2>&1 || EC=$?
assert_eq 2 "$(wc -l < "$counter" | tr -d ' ')" \
  "retry: a check that keeps failing still costs exactly two dispatches"
assert_eq 0 "$EC" "retry: a still-failing check stays warn-only (exit 0)"
assert_contains '"checks_failed_names":["subject_max"]' "$(tail -1 "$metrics")" \
  "retry: the post-retry check state is what the metrics row records"

# 47e. The row says whether a retry happened, so the cost is measurable.
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "retry: a retried call is marked on the metrics row"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
run_rt >/dev/null 2>&1
if [[ "$(tail -1 "$metrics")" == *'"retried"'* ]]; then
  echo "  FAIL  retry: a call that was not retried must carry no retried field"; fail=$((fail+1))
else
  echo "  PASS  retry: a call that was not retried carries no retried field"; pass=$((pass+1))
fi

# 47e-i. The rejected generation and the notice ride retry_chars rather than
# inflating prompt_chars / output_chars, and the row still reproduces its
# own token count.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" \
  'this subject line is far too long\n\nbody' \
  'short one\n\nbody'
run_rt >/dev/null 2>&1
row=$(tail -1 "$metrics")
rc=$(printf '%s' "$row" | jq -r '.retry_chars // 0')
if (( rc > 0 )); then
  echo "  PASS  retry: the rejected generation and the notice are counted"; pass=$((pass+1))
else
  echo "  FAIL  retry: the rejected generation and the notice are counted (retry_chars=$rc)"; fail=$((fail+1))
fi
assert_eq "$(printf '%s' "$row" | jq -r '((.prompt_chars + .context_chars + .output_chars + .retry_chars) / 4 | floor)')" \
  "$(printf '%s' "$row" | jq -r '.estimated_tokens_avoided')" \
  "retry: the row still reproduces its own token count"

# 46-ii. A delegation from outside any git repository writes no project
# field rather than the scratch directory's name.
: > "$metrics"
outside="$tmp/not-a-repo"; mkdir -p "$outside"
make_mock_curl_ok "$tmp"
( cd "$outside" && env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" prose "go" </dev/null >/dev/null 2>&1 )
if [[ "$(tail -1 "$metrics" | jq -r 'has("project")')" == "false" ]]; then
  echo "  PASS  project: a delegation outside a repo writes no project field"; pass=$((pass+1))
else
  echo "  FAIL  project: a delegation outside a repo writes no project field (got $(tail -1 "$metrics" | jq -r '.project'))"; fail=$((fail+1))
fi
( cd "$outside" && env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" --project delegate-local prose "go" </dev/null >/dev/null 2>&1 )
assert_eq "delegate-local" "$(tail -1 "$metrics" | jq -r '.project')" \
  "project: --project still names it from outside a repo"

# 47e-i-b. The rejected generation is measured before the checks run, since
# the auto-strip mutates $output in place. Differential, because a retried
# row reports only the post-retry check state: two first outputs that differ
# by a trailing padding clause must differ in retry_chars by that clause.
prompts2="$tmp/prompts2"; mkdir -p "$prompts2"
cat > "$prompts2/rp.md" <<'EOF'
---
tier: prose
checks:
  subject_max: 12
  no_padding_tail: true
---
# rp

## When to use
n/a

## Prompt template

```
GO
```

## Calibration notes
n/a
EOF
run_rp() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    ${1:+DELEGATE_NO_RETRY=1} \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts2" \
    bash "$SCRIPT" --recipe rp prose "go" </dev/null
}
plain_body='this subject line is far too long\n\nthe body says a thing'
padded_body="${plain_body}, ensuring the change is covered"
# Precondition: the padded tail is one the auto-strip takes.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$padded_body"
run_rp off >/dev/null 2>&1
assert_eq 1 "$(tail -1 "$metrics" | jq -r '.checks_autofixed')" \
  "retry: the padded tail used below is one the auto-strip takes"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$plain_body" 'short one\n\nbody'
run_rp >/dev/null 2>&1
rc_plain=$(tail -1 "$metrics" | jq -r '.retry_chars')
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$padded_body" 'short one\n\nbody'
run_rp >/dev/null 2>&1
rc_padded=$(tail -1 "$metrics" | jq -r '.retry_chars')
if (( rc_padded > rc_plain )); then
  echo "  PASS  retry: the rejected generation is measured before the auto-strip"; pass=$((pass+1))
else
  echo "  FAIL  retry: the rejected generation is measured before the auto-strip (plain=$rc_plain padded=$rc_padded)"; fail=$((fail+1))
fi

# 47e-ii. duration_ms covers both dispatches, so queue_wait_ms carries both
# waits; the mock reports 1 ms per dispatch.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" \
  'this subject line is far too long\n\nbody' \
  'short one\n\nbody'
run_rt >/dev/null 2>&1
assert_eq 2 "$(tail -1 "$metrics" | jq -r '.queue_wait_ms')" \
  "retry: queue_wait_ms carries both dispatches' waits"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
run_rt >/dev/null 2>&1
assert_eq 1 "$(tail -1 "$metrics" | jq -r '.queue_wait_ms')" \
  "retry: a single dispatch still reads one wait"

# 47e-iii. The OTel span carries the same retry_chars as the row.
: > "$metrics"
otel_body="$tmp/otel.json"
cat > "$tmp/curl.otel" <<'OEOF'
#!/usr/bin/env bash
OEOF
make_mock_curl_seq "$tmp" "$counter" \
  'this subject line is far too long\n\nbody' \
  'short one\n\nbody'
# Wrap the mock so the OTLP POST is captured rather than answered as a chat.
mv "$tmp/curl" "$tmp/curl.chat"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in *otlp.example.com*) cat > "$otel_body"; exit 0 ;; esac
done
exec "$tmp/curl.chat" "\$@"
EOF
chmod +x "$tmp/curl"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe rt prose "go" </dev/null >/dev/null 2>&1
assert_eq "$(tail -1 "$metrics" | jq -r '.retry_chars')" \
  "$(jq -r '[.. | objects | select(.key? == "delegate.retry_chars") | .value.intValue] | .[0]' "$otel_body" 2>/dev/null)" \
  "retry: the span carries the same retry_chars as the row"
# int64 is a JSON string in OTLP/JSON, like every other intValue on the span.
assert_eq "string" \
  "$(jq -r '[.. | objects | select(.key? == "delegate.retry_chars") | .value.intValue | type] | .[0]' "$otel_body" 2>/dev/null)" \
  "retry: delegate.retry_chars intValue is a JSON string"
mv "$tmp/curl.chat" "$tmp/curl"

# 47f. DELEGATE_NO_RETRY=1 restores the single-call behaviour exactly.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'this subject line is far too long\n\nbody'
out=$(run_rt off 2>&1)
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "retry: DELEGATE_NO_RETRY=1 dispatches once even on a failure"
assert_contains "check 'subject_max' FAILED" "$out" \
  "retry: DELEGATE_NO_RETRY=1 still reports the failure"

# 47g. A bare call declares no checks, so it is never retried.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'this subject line is far too long\n\nbody'
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "go" </dev/null >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "retry: a bare call is never retried"
rm -rf "$tmp" "$metrics"

# --- no_invented_headings: same contract as no_invented_task_list, for
# markdown headings ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/hd.md" <<'EOF'
---
tier: prose
checks:
  no_invented_headings: examples
---
# hd

## When to use
n/a

## Prompt template

```
Examples: {{examples}}
```

## Calibration notes
n/a
EOF
run_hd() {
  env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_NO_ECHO_CHECK=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe hd --var examples="$1" prose "go" </dev/null 2>&1 >/dev/null
}

# Headings with bullets under them, against heading-free exemplars.
make_mock_curl_think "$tmp" 'A paragraph of prose.\n\n### Implementation Details\n- Capture: pre-post.\n\n### Testing\n- 18 new assertions.'
out=$(run_hd $'TITLE: a merged PR\nBODY:\nTwo sentences of prose. No headings at all.')
assert_contains "check 'no_invented_headings' FAILED" "$out" \
  "no_invented_headings: an invented heading fails"
assert_contains "carries 2 markdown heading(s)" "$out" \
  "no_invented_headings: the count is named"
assert_contains '"checks_failed_names":["no_invented_headings"]' "$(tail -1 "$metrics")" \
  "no_invented_headings: named on the metrics row"

# When the examples carry headings the output is matching its shape.
if [[ "$(run_hd $'TITLE: a merged PR\nBODY:\n## Summary\nWhat it does.')" == *"no_invented_headings"* ]]; then
  echo "  FAIL  no_invented_headings: a heading the examples also carry must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_headings: a heading the examples also carry passes"; pass=$((pass+1))
fi

# Heading-free output against heading-free examples: silent.
make_mock_curl_think "$tmp" 'Just prose, two sentences of it. Nothing else.'
if [[ "$(run_hd $'TITLE: a merged PR\nBODY:\nprose')" == *"no_invented_headings"* ]]; then
  echo "  FAIL  no_invented_headings: output with no heading must pass"; fail=$((fail+1))
else
  echo "  PASS  no_invented_headings: output with no heading passes"; pass=$((pass+1))
fi

# A shell comment inside a fenced block is not a heading.
make_mock_curl_think "$tmp" 'Prose about the fix.\n\n```bash\n# run the suite\nbash tests/run-tests.sh\n```\n\nMore prose.'
if [[ "$(run_hd $'TITLE: a merged PR\nBODY:\nprose')" == *"no_invented_headings"* ]]; then
  echo "  FAIL  no_invented_headings: a comment inside a fenced block is not a heading"; fail=$((fail+1))
else
  echo "  PASS  no_invented_headings: a comment inside a fenced block is not a heading"; pass=$((pass+1))
fi

# A shebang has no space after the hash, so it is not a heading either.
make_mock_curl_think "$tmp" 'Prose.\n\n#!/usr/bin/env bash is the first line of the script.'
if [[ "$(run_hd $'TITLE: a merged PR\nBODY:\nprose')" == *"no_invented_headings"* ]]; then
  echo "  FAIL  no_invented_headings: a shebang is not a heading"; fail=$((fail+1))
else
  echo "  PASS  no_invented_headings: a shebang is not a heading"; pass=$((pass+1))
fi

# Fences in the examples are skipped too, or a snippet comment would read as
# the exemplar carrying headings and silence the check.
make_mock_curl_think "$tmp" 'Prose.\n\n## Summary\nInvented.'
assert_contains "check 'no_invented_headings' FAILED" \
  "$(run_hd $'TITLE: a merged PR\nBODY:\nprose\n```bash\n# not a heading\nls\n```')" \
  "no_invented_headings: a fenced comment in the examples is not a heading either"
rm -rf "$tmp" "$metrics"

# --- 48. no_context_echo (#475): opt-in per recipe, fails when two or more
# distinct piped sentences come back verbatim; one is legitimate anchor-carrying ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/ce.md" <<'EOF'
---
tier: prose
checks:
  no_context_echo: true
---
# ce

## When to use
n/a

## Prompt template

```
Reply using only the facts below.

=== VERDICT ===
{{verdict}}

=== FACTS ===
{{stdin}}
```

## Calibration notes
n/a
EOF
ce_facts=$'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe regression predates the refactor by two releases.'
ce_verdict='The rework is right and the blank window is not a regression from it at all.'
run_ce() {
  # $1 selects the recipe; $ce_facts is piped and $ce_verdict is the --var.
  printf '%s\n' "$ce_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe "${1:-ce}" --var verdict="$ce_verdict" prose "go" 2>&1 >/dev/null
}

# 48a. Two supplied lines handed straight back -> FAILED, named, counted.
: > "$metrics"
make_mock_curl_think "$tmp" 'Not a regression.\nThe GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nCould you add a test?'
out=$(run_ce)
assert_contains "check 'no_context_echo' FAILED" "$out" \
  "context-echo: two supplied lines reproduced verbatim are caught"
assert_contains "2 distinct sentence(s)" "$out" \
  "context-echo: the failure counts the distinct echoed sentences"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_context_echo"]' "$row" \
  "context-echo: named on the metrics row"
assert_contains '"checks_run":2' "$row" \
  "context-echo: counted in checks_run beside the default echo check"

# 48a-ii. Facts are piped one per line and come back joined into a paragraph,
# so the unit is the sentence, not the line.
make_mock_curl_think "$tmp" 'Not a regression. The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412. All 531 tests pass on the branch with the flag forced back on, see PR #2632. Could you add a test?'
out=$(run_ce)
assert_contains "check 'no_context_echo' FAILED" "$out" \
  "context-echo: two facts joined into one paragraph line are still caught"

# 48a-iv. Facts often arrive without full stops and come back with them, so
# the terminator is not part of the unit.
ce_facts_bare=$(printf "%s\n" "$ce_facts" | sed "s/\.$//")
: > "$metrics"
make_mock_curl_think "$tmp" "Not a regression. The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412. All 531 tests pass on the branch with the flag forced back on, see PR #2632. Could you add a test?"
out=$(printf "%s\n" "$ce_facts_bare" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe ce --var verdict="$ce_verdict" prose "go" 2>&1 >/dev/null)
assert_contains "check 'no_context_echo' FAILED" "$out" \
  "context-echo: facts piped without full stops are caught when echoed as sentences"

# 48a-iii. A --var value is not a pattern: the verdict plus one fact is one
# echoed sentence, not two.
: > "$metrics"
make_mock_curl_think "$tmp" "${ce_verdict} The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412. Could you add a test?"
out=$(run_ce)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: a reproduced --var value must not count as an echo"; fail=$((fail+1))
else
  echo "  PASS  context-echo: a reproduced --var value does not count as an echo"; pass=$((pass+1))
fi
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "context-echo: the --var case still ran the check"

# 48b. Anchors carried inside new sentences never flag.
make_mock_curl_think "$tmp" 'Not a regression.\nThe flip is in the Electron 39 upgrade, specifically the sandbox flag at src/main.js:412, two releases before the refactor.\nI re-ran the suite with the flag forced back on and all 531 tests pass, so PR #2632 is not the cause.\nCould you add a test?'
: > "$metrics"
out=$(run_ce)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: anchors carried in new sentences must not flag"; fail=$((fail+1))
else
  echo "  PASS  context-echo: anchors carried in new sentences do not flag"; pass=$((pass+1))
fi
# Silence must mean "ran and passed", not "never ran".
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "context-echo: the silent case still ran the check"

# 48c. One echoed line is quoting a fact: below the threshold.
make_mock_curl_think "$tmp" 'Not a regression.\nThe GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nThe refactor is two releases newer, so the failure is the flag.\nCould you add a test?'
out=$(run_ce)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: a single echoed line must stay below the threshold"; fail=$((fail+1))
else
  echo "  PASS  context-echo: a single echoed line stays below the threshold"; pass=$((pass+1))
fi

# 48c-i. The same line echoed twice is still one supplied line.
make_mock_curl_think "$tmp" 'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nThe GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.'
out=$(run_ce)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: one line repeated is one line, not two"; fail=$((fail+1))
else
  echo "  PASS  context-echo: one line repeated is one line, not two"; pass=$((pass+1))
fi

# 48d. Short lines sit below the same 40-char floor as no_example_echo.
ce_facts_saved="$ce_facts"
ce_facts=$'Thanks again!\n=== FACTS ===\nA third short line.'
make_mock_curl_think "$tmp" 'Thanks again!\n=== FACTS ===\nA third short line.'
out=$(run_ce)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: short shared lines must stay below the length floor"; fail=$((fail+1))
else
  echo "  PASS  context-echo: short shared lines stay below the length floor"; pass=$((pass+1))
fi
ce_facts="$ce_facts_saved"

# 48e. Same normalisation as no_example_echo: surrounding whitespace and a
# `Correct:` label do not hide an echo.
make_mock_curl_think "$tmp" '   The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.  \nCorrect: All 531 tests pass on the branch with the flag forced back on, see PR #2632.'
out=$(run_ce)
assert_contains "check 'no_context_echo' FAILED" "$out" \
  "context-echo: whitespace and a label prefix are normalised away before comparing"

# 48f. Opt-in: an undeclared recipe never runs it.
cat > "$prompts/ce_off.md" <<'EOF'
---
tier: prose
---
# ce_off

## When to use
n/a

## Prompt template

```
Reply using only the facts below.

=== FACTS ===
{{stdin}}
```

## Calibration notes
n/a
EOF
: > "$metrics"
make_mock_curl_think "$tmp" 'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.'
out=$(run_ce ce_off)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: an undeclared check must not run"; fail=$((fail+1))
else
  echo "  PASS  context-echo: an undeclared check does not run"; pass=$((pass+1))
fi
assert_contains '"checks_run":1' "$(tail -1 "$metrics")" \
  "context-echo: undeclared, only the default echo check is counted"

# 48f-ii. DELEGATE_NO_ECHO_CHECK=1 silences both echo checks.
: > "$metrics"
make_mock_curl_think "$tmp" 'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.'
out=$(printf '%s\n' "$ce_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_ECHO_CHECK=1 DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe ce --var verdict="$ce_verdict" prose "go" 2>&1 >/dev/null)
if [[ "$out" == *"no_context_echo"* ]]; then
  echo "  FAIL  context-echo: DELEGATE_NO_ECHO_CHECK=1 must silence it too"; fail=$((fail+1))
else
  echo "  PASS  context-echo: DELEGATE_NO_ECHO_CHECK=1 silences it too"; pass=$((pass+1))
fi
if [[ "$(tail -1 "$metrics")" == *'"checks_run"'* ]]; then
  echo "  FAIL  context-echo: an opted-out call must not count either echo check"; fail=$((fail+1))
else
  echo "  PASS  context-echo: an opted-out call counts neither echo check"; pass=$((pass+1))
fi

# 48g. Echo alone is NOT retried (#514): the second generation came back the
# same size and the same echo on 8 of the 12 maintainer-review-reply retries
# measured over 2026-09-13/14, so the notice does not repair it and the
# retry is a wasted generation. The check still fails, prints its reject and
# is named on the row; the row carries no retried / retry_chars.
counter="$tmp/calls"
make_mock_curl_seq "$tmp" "$counter" \
  'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.' \
  'The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on, so PR #2632 is clear.'
: > "$metrics"
err=$(mktemp)
out=$(printf '%s\n' "$ce_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe ce --var verdict="$ce_verdict" prose "go" 2>"$err")
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "context-echo: echo alone costs exactly one dispatch (no retry, #514)"
assert_contains "All 531 tests pass on the branch" "$out" \
  "context-echo: the caller receives the flagged first generation"
assert_contains "check 'no_context_echo' FAILED" "$(cat "$err")" \
  "context-echo: the reject is still printed when no retry follows"
if [[ "$(cat "$err")" == *"regenerating once"* ]]; then
  echo "  FAIL  context-echo: echo alone must not announce a regeneration"; fail=$((fail+1))
else
  echo "  PASS  context-echo: echo alone announces no regeneration"; pass=$((pass+1))
fi
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_context_echo"]' "$row" \
  "context-echo: the skipped retry still names the failure on the row"
if [[ "$row" == *'"retried"'* ]] || [[ "$row" == *'"retry_chars"'* ]]; then
  echo "  FAIL  context-echo: echo alone must leave retried and retry_chars off the row"; fail=$((fail+1))
else
  echo "  PASS  context-echo: echo alone leaves retried and retry_chars off the row"; pass=$((pass+1))
fi
rm -f "$err"

# 48h. Echo beside another failed check still takes the retry: the gate is
# "only echo failed", not "echo failed". max_context_ratio is the realistic
# partner (both reply recipes declare the pair), so the context has to clear
# the ratio floor.
cat > "$prompts/cer.md" <<'EOF'
---
tier: prose
checks:
  no_context_echo: true
  max_context_ratio: 0.8
---
# cer

## When to use
n/a

## Prompt template

```
Reply using only the facts below.

=== FACTS ===
{{stdin}}
```

## Calibration notes
n/a
EOF
cer_facts=""
for i in 1 2 3 4 5 6; do
  cer_facts="${cer_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 now.
"
done
make_mock_curl_seq "$tmp" "$counter" \
  "$(printf '%s' "$cer_facts" | tr '\n' ' ')" \
  'The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.'
: > "$metrics"
out=$(printf '%s\n' "$cer_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe cer prose "go" 2>/dev/null)
assert_eq 2 "$(wc -l < "$counter" | tr -d ' ')" \
  "context-echo: echo beside max_context_ratio still costs two dispatches"
assert_contains "so the branch is clear" "$out" \
  "context-echo: the caller receives the retried output when another check drove the retry"
assert_contains "max_context_ratio: the answer runs about as long as the supplied facts" "$(cat "$tmp/payload.2.json")" \
  "context-echo: the second request names the check that drove the retry"
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "context-echo: a retry driven by another check is marked on the row"
if [[ "$(tail -1 "$metrics")" == *'"checks_failed_names"'* ]]; then
  echo "  FAIL  context-echo: a clean retry must leave no failed check on the row"; fail=$((fail+1))
else
  echo "  PASS  context-echo: a clean retry leaves no failed check on the row"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 49. max_context_ratio (#487): fails when output_chars / context_chars
# >= the declared ratio and the context is at least min_context_chars
# (default 400); opt-in, warn-only, retried with its own constraint ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
mcr_recipe() {
  # $1 = recipe basename, $2.. = the checks block lines, verbatim.
  local name="$1"; shift
  { printf -- '---\ntier: prose\nchecks:\n'; printf '  %s\n' "$@"; printf -- '---\n'
    printf '# %s\n\n## When to use\nn/a\n\n## Prompt template\n\n```\nReply using only the facts below.\n\n=== FACTS ===\n{{stdin}}\n```\n\n## Calibration notes\nn/a\n' "$name"; } > "$prompts/$name.md"
}
mcr_recipe mcr 'max_context_ratio: 0.8'
mcr_recipe mcr_floor 'max_context_ratio: 0.8' 'min_context_chars: 2000'
mcr_recipe mcr_none 'no_padding_tail: true'
# Eight facts of ~90 chars: well over the 400-char default floor.
mcr_facts=""
for i in 1 2 3 4 5 6 7 8; do
  mcr_facts="${mcr_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 now.
"
done
mcr_short_facts=$'The sandbox flag flip is at src/main.js:412.\nAll 531 tests pass on PR #2632.'
# A long answer (~7 sentences of ~100 chars, ratio near 1.0) and a short one.
mcr_long='The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now. The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.'
mcr_short='The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.'
run_mcr() {
  # $1 = recipe, $2 = the piped facts; no retry so the first pass lands on the row.
  printf '%s\n' "$2" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe "$1" prose "go" 2>&1 >/dev/null
}

# 49a. Long answer against a long context -> FAILED, named, counted.
: > "$metrics"
make_mock_curl_think "$tmp" "$mcr_long"
out=$(run_mcr mcr "$mcr_facts")
assert_contains "check 'max_context_ratio' FAILED" "$out" \
  "context-ratio: an answer as long as its facts is caught"
assert_contains ">= 0.8" "$out" \
  "context-ratio: the failure names the declared ratio"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["max_context_ratio"]' "$row" \
  "context-ratio: named on the metrics row"
assert_contains '"checks_run":2' "$row" \
  "context-ratio: counted in checks_run beside the default echo check"

# 49b. A curated answer well under the ratio passes, and still counts as run.
: > "$metrics"
make_mock_curl_think "$tmp" "$mcr_short"
out=$(run_mcr mcr "$mcr_facts")
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  context-ratio: an answer well under the ratio must pass ($out)"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: an answer well under the ratio passes"; pass=$((pass+1))
fi
row=$(tail -1 "$metrics")
assert_contains '"checks_run":2' "$row" \
  "context-ratio: a passing check is still counted as run"
if [[ "$row" == *'"checks_failed_names"'* ]]; then
  echo "  FAIL  context-ratio: a passing check must leave no failed name on the row"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: a passing check leaves no failed name on the row"; pass=$((pass+1))
fi

# 49c. A context under the floor is exempt whatever the ratio.
: > "$metrics"
make_mock_curl_think "$tmp" "$mcr_long"
out=$(run_mcr mcr "$mcr_short_facts")
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  context-ratio: a context under the floor must be exempt ($out)"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: a context under the default 400-char floor is exempt"; pass=$((pass+1))
fi

# 49c-ii. A declared min_context_chars above the context length exempts it.
: > "$metrics"
make_mock_curl_think "$tmp" "$mcr_long"
out=$(run_mcr mcr_floor "$mcr_facts")
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  context-ratio: a declared min_context_chars above the context must exempt it ($out)"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: a declared min_context_chars above the context exempts it"; pass=$((pass+1))
fi
if [[ "$out" == *"unknown check 'min_context_chars'"* ]]; then
  echo "  FAIL  context-ratio: min_context_chars must be accepted as the floor, not reported unknown"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: min_context_chars is accepted beside the ratio"; pass=$((pass+1))
fi

# 49d. Undeclared recipes never run it, however long the answer.
: > "$metrics"
make_mock_curl_think "$tmp" "$mcr_long"
out=$(run_mcr mcr_none "$mcr_facts")
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  context-ratio: an undeclared recipe must not run it ($out)"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: an undeclared recipe never runs it"; pass=$((pass+1))
fi
if [[ "$(tail -1 "$metrics")" == *'max_context_ratio'* ]]; then
  echo "  FAIL  context-ratio: an undeclared recipe must not name it on the row"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: an undeclared recipe leaves it off the row"; pass=$((pass+1))
fi

# 49e. The retry carries its own constraint sentence and a clean second
# generation clears the row.
counter="$tmp/calls"
make_mock_curl_seq "$tmp" "$counter" "$mcr_long" "$mcr_short"
: > "$metrics"
out=$(printf '%s\n' "$mcr_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe mcr prose "go" 2>/dev/null)
assert_eq 2 "$(wc -l < "$counter" | tr -d ' ')" \
  "context-ratio: a failed check costs exactly two dispatches"
assert_contains "max_context_ratio: the answer runs about as long as the supplied facts; curate it to well under the facts' length, in sentences of your own." "$(cat "$tmp/payload.2.json")" \
  "context-ratio: the second request carries the length constraint sentence"
if [[ "$(cat "$tmp/payload.2.json")" == *"no_context_echo:"* ]]; then
  echo "  FAIL  context-ratio: the retry must not name a check that did not fail"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: the retry names only the check that failed"; pass=$((pass+1))
fi
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "context-ratio: the retry is marked on the metrics row"
if [[ "$(tail -1 "$metrics")" == *'"checks_failed_names"'* ]]; then
  echo "  FAIL  context-ratio: a clean retry must leave no failed check on the row"; fail=$((fail+1))
else
  echo "  PASS  context-ratio: a clean retry leaves no failed check on the row"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# --- 50. maintainer-review-reply sets min_context_chars: 900 (#514): 2 of
# the 5 shipped replies in the spike set, 789 chars on 832 of facts and 813
# on 693, failed the ratio under the default 400 floor although the
# maintainer shipped them, and no shipped reply in that set over 900 chars
# of facts exceeds it. Run against the REAL recipe so the value is proved
# through the wrapper, not just read off the file ---
tmp=$(mktemp -d)
metrics=$(mktemp)
mrr="$REPO/prompts/maintainer-review-reply.md"
mrr_fm=$(awk '/^---[[:space:]]*$/{d++; if (d==2) exit; next} d==1' "$mrr")
if printf '%s\n' "$mrr_fm" | grep -qE '^[[:space:]]+min_context_chars:[[:space:]]*900[[:space:]]*$'; then
  echo "  PASS  review-reply floor: maintainer-review-reply.md declares min_context_chars: 900"; pass=$((pass+1))
else
  echo "  FAIL  review-reply floor: maintainer-review-reply.md does not declare min_context_chars: 900"; fail=$((fail+1))
fi
# Facts long enough to cut at any length; the cut lands mid-line so the
# trailing character is never a newline (which $(cat) would strip).
mrr_facts=""
for i in 1 2 3 4 5 6 7 8 9; do
  mrr_facts="${mrr_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 with it forced back on.
"
done
mrr_ctx_at() { printf '%s' "$mrr_facts" | head -c "$1"; }
# One paragraph of the model's own sentences: no echoed fact, no list, no
# padding tail, so only the ratio can fail. Longer than either shipped size
# so head -c reproduces them exactly; whole, it is 0.97 of 900.
mrr_reply='The change is right and the flag path is not a regression. The flip lives at src/main.js:412 and predates this branch, and with it forced back on the suite is green at 531 tests on PR #2632, which is the same count main reports. The three call sites you collapsed now share one assignment, so the sandbox flag is read in one place and the blank-window report cannot come back through a second path. I re-ran the suite twice on your branch to rule out an ordering effect and both runs passed at 531. The remaining question is coverage rather than correctness: nothing in the suite exercises the forced-on path directly, so a later refactor could drop it without a test going red. The CI failure you saw is the flag and not the refactor, and the log on that run says so in its first line. Could you add a regression test that covers the sandbox flag path before we merge this?'
run_mrr() {
  # $1 = the context length to cut the facts at; DELEGATE_NO_RETRY so the
  # first pass lands on the row.
  mrr_ctx_at "$1" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$REPO/prompts" \
    bash "$SCRIPT" --recipe maintainer-review-reply --var verdict="the change is right" prose "go" 2>&1 >/dev/null
}
# Measured the way delegate.sh measures it: $(cat) strips trailing newlines.
mrr_ctx_900=$(mrr_ctx_at 900)
assert_eq 900 "${#mrr_ctx_900}" "review-reply floor: the fixture reads as exactly 900 chars"
# 50a. The two shipped sizes from the spike set pass: 789 on 832 and 813 on 693.
: > "$metrics"
make_mock_curl_think "$tmp" "$(printf '%s' "$mrr_reply" | head -c 789)"
out=$(run_mrr 832)
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  review-reply floor: a 789-char reply on 832 chars of facts must pass ($out)"; fail=$((fail+1))
else
  echo "  PASS  review-reply floor: a 789-char reply on 832 chars of facts passes"; pass=$((pass+1))
fi
if [[ "$(tail -1 "$metrics")" == *'"checks_failed_names"'* ]]; then
  echo "  FAIL  review-reply floor: the 832-char case must leave no failed check on the row ($(tail -1 "$metrics"))"; fail=$((fail+1))
else
  echo "  PASS  review-reply floor: the 832-char case leaves no failed check on the row"; pass=$((pass+1))
fi
: > "$metrics"
make_mock_curl_think "$tmp" "$(printf '%s' "$mrr_reply" | head -c 813)"
out=$(run_mrr 693)
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  review-reply floor: an 813-char reply on 693 chars of facts must pass ($out)"; fail=$((fail+1))
else
  echo "  PASS  review-reply floor: an 813-char reply on 693 chars of facts passes"; pass=$((pass+1))
fi
# 50b. The floor is exactly 900: 899 chars of facts are exempt, 900 are not.
make_mock_curl_think "$tmp" "$mrr_reply"
: > "$metrics"
out=$(run_mrr 899)
if [[ "$out" == *"max_context_ratio"* ]]; then
  echo "  FAIL  review-reply floor: 899 chars of facts must be exempt ($out)"; fail=$((fail+1))
else
  echo "  PASS  review-reply floor: 899 chars of facts are exempt"; pass=$((pass+1))
fi
: > "$metrics"
out=$(run_mrr 900)
assert_contains "check 'max_context_ratio' FAILED" "$out" \
  "review-reply floor: 900 chars of facts are checked and a 0.97 ratio fails"
assert_contains 'max_context_ratio' "$(tail -1 "$metrics")" \
  "review-reply floor: the 900-char failure is named on the row"
rm -rf "$tmp" "$metrics"

# --- 51. no_fact_as_question (#513): opt-in per recipe, the value names the
# --var holding the asks; fails when a question's anchors are all in the
# piped facts and none in that var (or, with no anchor, two-plus content
# words from the facts and none from the var). Never retried on its own. ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
fq_recipe() {
  # $1 = recipe basename, $2.. = the checks block lines, verbatim.
  local name="$1"; shift
  { printf -- '---\ntier: prose\nchecks:\n'; printf '  %s\n' "$@"; printf -- '---\n'
    printf '# %s\n\n## When to use\nn/a\n\n## Prompt template\n\n```\nReply using only the facts below.\n\n=== OPENER ===\n{{opener}}\n\n=== ASK ===\n{{ask}}\n\n=== FACTS ===\n{{stdin}}\n```\n\n## Calibration notes\nn/a\n' "$name"; } > "$prompts/$name.md"
}
fq_recipe fq 'no_fact_as_question: ask'
fq_recipe fq_list 'no_single_item_list: true' 'no_fact_as_question: ask'
fq_recipe fq_echo 'no_context_echo: true' 'no_fact_as_question: ask'
fq_recipe fq_off 'no_padding_tail: true'
fq_facts=$'The blank window is the GPU sandbox flag flip in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe token drop is on the Teams side, in its MSAL cache, not in teams-for-linux.'
fq_ask='whether the token survives a cold start of the app'
run_fq() {
  # $1 = recipe, $2 = the ask var; $fq_facts is piped, no retry.
  printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe "$1" --var ask="${2:-$fq_ask}" --var opener="Thanks for the report on build 4711." prose "go" 2>&1 >/dev/null
}

# 51a. A fact with anchors handed back as a question -> FAILED, quoted, named, counted.
: > "$metrics"
make_mock_curl_think "$tmp" 'Not a regression, the flip is the sandbox flag at src/main.js:412. Could you confirm that all 531 tests pass on PR #2632?'
out=$(run_fq fq)
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: a fact's anchors asked back to the reader are caught"
assert_contains 'Could you confirm that all 531 tests pass on PR #2632?' "$out" \
  "fact-question: the offending question is quoted"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_fact_as_question"]' "$row" \
  "fact-question: named on the metrics row"
assert_contains '"checks_run":2' "$row" \
  "fact-question: counted in checks_run beside the default echo check"

# 51a-ii. No anchor at all: two-plus content words from the facts and none
# from the ask is the same fact asked back.
: > "$metrics"
make_mock_curl_think "$tmp" 'The flip is the sandbox flag in the Electron 39 upgrade. Can you confirm the tests pass with the flag forced back on?'
out=$(run_fq fq)
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: a fact without anchors asked back is caught on its content words"
assert_contains 'Can you confirm the tests pass with the flag forced back on?' "$out" \
  "fact-question: the zero-anchor question is the one quoted"

# 51a-iii. A MULTI-ASK-SPLIT item is a question of its own, arriving bare.
make_mock_curl_think "$tmp" 'The flip is the sandbox flag at src/main.js:412.\n1. Could you confirm that all 531 tests pass on PR #2632?\n2. Could you check whether the token survives a cold start of the app?'
out=$(run_fq fq)
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: a numbered item that asks a fact back is caught"
assert_contains ': "Could you confirm that all 531 tests pass on PR #2632?"' "$out" \
  "fact-question: the numbered item is quoted without its number"

# 51b. The caller's ask as a question is the recipe's shape: never flagged,
# still counted as run.
: > "$metrics"
make_mock_curl_think "$tmp" 'The flip is the sandbox flag at src/main.js:412 in the Electron 39 upgrade. Could you check whether the token survives a cold start of the app?'
out=$(run_fq fq)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: the caller's ask phrased as a question must pass ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: the caller's ask phrased as a question passes"; pass=$((pass+1))
fi
row=$(tail -1 "$metrics")
assert_contains '"checks_run":2' "$row" \
  "fact-question: the silent case still ran the check"
if [[ "$row" == *'"checks_failed_names"'* ]]; then
  echo "  FAIL  fact-question: a passing check must leave no failed name on the row"; fail=$((fail+1))
else
  echo "  PASS  fact-question: a passing check leaves no failed name on the row"; pass=$((pass+1))
fi

# 51b-ii. An anchor the ask var carries is the caller's, even when the facts
# carry it too.
make_mock_curl_think "$tmp" 'The flip is the sandbox flag at src/main.js:412. Does PR #2632 still reproduce it on your machine?'
out=$(run_fq fq 'whether PR #2632 still reproduces it')
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: an anchor named in the ask var must not flag ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: an anchor named in the ask var is the caller's ask"; pass=$((pass+1))
fi

# 51c. An anchor the facts do not hold is the model's own question, not a fact.
make_mock_curl_think "$tmp" 'The flip is the sandbox flag at src/main.js:412. Could you try Electron 40 and report back?'
out=$(run_fq fq)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: an anchor outside the facts must not flag ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: an anchor outside the facts is not a supplied fact"; pass=$((pass+1))
fi

# 51c-ii. One shared content word is any question at all: below the floor.
make_mock_curl_think "$tmp" 'The flip is the sandbox flag at src/main.js:412. Could you paste the flag you use?'
out=$(run_fq fq)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: one shared word must stay below the floor ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: one shared word stays below the two-word floor"; pass=$((pass+1))
fi

# 51c-iii. Only the piped facts are a source: a --var value asked back is not
# a supplied fact (the mirror of 48a-iii).
make_mock_curl_think "$tmp" 'Thanks for the report on build 4711. The flip is the sandbox flag at src/main.js:412. Could you confirm the report was on build 4711?'
out=$(run_fq fq)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: a --var value asked back must not flag ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: a --var value asked back is not a supplied fact"; pass=$((pass+1))
fi

# 51c-iv. A question the caller wrote (an opener or sign-off, emitted
# verbatim) is the caller's whatever anchors it carries.
make_mock_curl_think "$tmp" 'Did all 531 tests pass on PR #2632 for you too? The flip is the sandbox flag at src/main.js:412. Could you check whether the token survives a cold start of the app?'
out=$(printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe fq --var ask="$fq_ask" --var opener="Did all 531 tests pass on PR #2632 for you too?" prose "go" 2>&1 >/dev/null)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: a caller-supplied opener that is a question must not flag ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: a caller-supplied opener that is a question is the caller's"; pass=$((pass+1))
fi

# 51c-v. The recipe puts the recipient handle in front of the opener, so the
# emitted unit is "@handle, <opener>"; the caller's question inside it is
# still the caller's.
make_mock_curl_think "$tmp" '@nneul, Did all 531 tests pass on PR #2632 for you too? The flip is the sandbox flag at src/main.js:412. Could you check whether the token survives a cold start of the app?'
out=$(printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe fq --var ask="$fq_ask" --var recipient="nneul" --var opener="Did all 531 tests pass on PR #2632 for you too?" prose "go" 2>&1 >/dev/null)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: a caller-supplied opener behind the recipient handle must not flag ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: a caller-supplied opener behind the recipient handle is the caller's"; pass=$((pass+1))
fi

# 51d. Never retried on its own: one dispatch, the failure stays on the row
# and its stderr reaches the caller.
counter="$tmp/calls"
make_mock_curl_seq "$tmp" "$counter" \
  'Not a regression, the flip is the sandbox flag at src/main.js:412. Could you confirm that all 531 tests pass on PR #2632?' \
  'The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on. Could you check whether the token survives a cold start of the app?'
: > "$metrics"
out=$(printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe fq --var ask="$fq_ask" --var opener="Thanks." prose "go" 2>&1 >/dev/null)
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "fact-question: a failure on its own costs exactly one dispatch"
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: the un-retried failure is reported to the caller"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_fact_as_question"]' "$row" \
  "fact-question: the un-retried failure is on the row"
if [[ "$row" == *'"retried"'* ]]; then
  echo "  FAIL  fact-question: the row must not be marked retried"; fail=$((fail+1))
else
  echo "  PASS  fact-question: the row is not marked retried"; pass=$((pass+1))
fi

# 51d-ii. Beside a check that does retry, the retry runs for that check and
# its notice names only that check.
make_mock_curl_seq "$tmp" "$counter" \
  'The flip is the sandbox flag at src/main.js:412.\n1. Could you confirm that all 531 tests pass on PR #2632?' \
  'The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on. Could you check whether the token survives a cold start of the app?'
: > "$metrics"
out=$(printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe fq_list --var ask="$fq_ask" --var opener="Thanks." prose "go" 2>&1 >/dev/null)
assert_eq 2 "$(wc -l < "$counter" | tr -d ' ')" \
  "fact-question: a retried check beside it still costs two dispatches"
assert_contains "check(s) no_single_item_list failed" "$out" \
  "fact-question: the retry line names only the check that earns it"
if [[ "$(cat "$tmp/payload.2.json")" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: the retry notice must not carry this check"; fail=$((fail+1))
else
  echo "  PASS  fact-question: the retry notice leaves this check out"; pass=$((pass+1))
fi
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "fact-question: the other check's retry is marked on the row"

# 51d-iii. Beside no_context_echo, which does not earn the retry on its own
# either (#514), nothing is regenerated and both are named on the row.
make_mock_curl_seq "$tmp" "$counter" \
  'The blank window is the GPU sandbox flag flip in the Electron 39 upgrade at src/main.js:412. All 531 tests pass on the branch with the flag forced back on, see PR #2632. Could you confirm that all 531 tests pass on PR #2632?' \
  'The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on. Could you check whether the token survives a cold start of the app?'
: > "$metrics"
out=$(printf '%s\n' "$fq_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe fq_echo --var ask="$fq_ask" --var opener="Thanks." prose "go" 2>&1 >/dev/null)
assert_eq 1 "$(wc -l < "$counter" | tr -d ' ')" \
  "fact-question: beside echo alone, neither earns the retry: one dispatch"
assert_contains '"checks_failed_names":["no_context_echo","no_fact_as_question"]' "$(tail -1 "$metrics")" \
  "fact-question: beside echo alone, both failures are named on the row"

# 51e. Undeclared recipes never run it.
: > "$metrics"
make_mock_curl_think "$tmp" 'Not a regression, the flip is the sandbox flag at src/main.js:412. Could you confirm that all 531 tests pass on PR #2632?'
out=$(run_fq fq_off)
if [[ "$out" == *"no_fact_as_question"* ]]; then
  echo "  FAIL  fact-question: an undeclared recipe must not run it ($out)"; fail=$((fail+1))
else
  echo "  PASS  fact-question: an undeclared recipe never runs it"; pass=$((pass+1))
fi
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "fact-question: undeclared, only the declared and default checks are counted"
rm -rf "$tmp" "$metrics"

# --- 52. maintainer-reply takes the lead from the caller (#517): the judgment
# sentence is a required input, so a call without it exits 2 naming it before
# any dispatch, and the rendered input the model saw (#516) carries the lead
# text between the opener and the facts. Run against the REAL recipe so the
# contract is proved through the wrapper, not read off the file ---
tmp=$(mktemp -d)
data="$tmp/data"; mkdir -p "$data"
metrics="$data/metrics.jsonl"
mr_facts='The token drop is on the Teams side, in its MSAL cache, not in teams-for-linux.'
mr_lead='Your trace was right, and this one is not ours to fix.'
mr_opener='Thanks for the clear report.'
# 52a. Without --var lead= the wrapper refuses, names the key, and dispatches
# nothing: the mock only serves discovery, so a dispatch would be visible as
# a metrics row or a non-2 exit.
make_mock_curl_models_only "$tmp"
out=$(printf '%s\n' "$mr_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$REPO/prompts" \
  bash "$SCRIPT" --recipe maintainer-reply --var ask="whether the token survives a cold start" \
    --var opener="$mr_opener" prose "go" 2>&1 >/dev/null)
rc=$?
assert_eq 2 "$rc" "lead: a maintainer-reply call without --var lead= exits 2"
assert_contains "missing required inputs: lead" "$out" "lead: the refusal names lead as the missing input"
if [[ ! -s "$metrics" ]]; then
  echo "  PASS  lead: the refusal writes no metrics row"; pass=$((pass+1))
else
  echo "  FAIL  lead: the refusal wrote a metrics row ($(tail -1 "$metrics"))"; fail=$((fail+1))
fi
# 52b. With it, the stored input holds the lead verbatim, after the opener
# and before the piped facts, so the model was shown it in that position.
make_mock_curl_think "$tmp" 'Your trace was right, and this one is not ours to fix. The drop is in the MSAL cache on the Teams side. Could you check whether the token survives a cold start?'
printf '%s\n' "$mr_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$REPO/prompts" \
  bash "$SCRIPT" --recipe maintainer-reply --var lead="$mr_lead" --var ask="whether the token survives a cold start" \
    --var opener="$mr_opener" prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
input_name=$(printf '%s' "$row" | jq -r '.input_file // ""')
if [[ -n "$input_name" && -f "$data/drafts/$input_name" ]]; then
  echo "  PASS  lead: the recipe call stores its rendered input"; pass=$((pass+1))
else
  echo "  FAIL  lead: no input file on the row (got '$input_name')"; fail=$((fail+1))
fi
input_body=$(cat "$data/drafts/$input_name" 2>/dev/null)
assert_contains "$mr_lead" "$input_body" "lead: the stored input carries the lead text verbatim"
lead_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_lead" | head -1 | cut -d: -f1)
opener_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_opener" | head -1 | cut -d: -f1)
facts_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_facts" | head -1 | cut -d: -f1)
if [[ -n "$lead_pos" && -n "$opener_pos" && -n "$facts_pos" ]] \
   && (( opener_pos < lead_pos && lead_pos < facts_pos )); then
  echo "  PASS  lead: the stored input places the lead after the opener and before the facts"; pass=$((pass+1))
else
  echo "  FAIL  lead: expected opener < lead < facts in the stored input (opener=$opener_pos lead=$lead_pos facts=$facts_pos)"; fail=$((fail+1))
fi
assert_eq 1 "$(printf '%s' "$input_body" | grep -c -F "$mr_lead")" \
  "lead: the lead appears exactly once in the stored input"
rm -rf "$tmp"

# --- 53. no_unbidden_mention: opt-in per recipe, the value names the --var
# holding the recipient handle; fails on any @-mention that is not that
# handle, and on every mention when no handle was supplied. Measured
# 2026-09-22 over the stored corpus: 42 of 82 rejected reply drafts carry
# one, 0 of 81 shipped replies do. ---
tmp=$(mktemp -d)
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
{ printf -- '---\ntier: prose\ninputs:\n  stdin: string\n  recipient: string?\nchecks:\n  no_unbidden_mention: recipient\n---\n'
  printf '# um\n\n## When to use\nn/a\n\n## Prompt template\n\n```\nReply using only the facts below.\n\n=== RECIPIENT ===\n{{recipient}}\n\n=== FACTS ===\n{{stdin}}\n```\n\n## Calibration notes\nn/a\n'; } > "$prompts/um.md"
um_facts=$'The crash is in src/main.js:412 and tomgunning reported it on the referenced issue.\nAll 531 tests pass on the branch.'
run_um() {
  # $1 = the recipient var value, passed only when non-empty.
  local args=()
  [[ -n "${1:-}" ]] && args=(--var "recipient=$1")
  printf '%s\n' "$um_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe um ${args[@]+"${args[@]}"} prose "go" 2>&1 >/dev/null
}

# 53a. No recipient supplied: any mention is unbidden, even when the name is
# in the piped facts (which is how both measured cases arose).
: > "$metrics"
make_mock_curl_think "$tmp" '@tomgunning, thanks for the report. The crash is at src/main.js:412 and all 531 tests pass.'
out=$(run_um)
assert_contains "check 'no_unbidden_mention' FAILED" "$out" \
  "unbidden-mention: a mention with no recipient supplied is caught"
assert_contains '@tomgunning' "$out" \
  "unbidden-mention: the offending handle is named"
assert_contains 'you supplied no' "$out" \
  "unbidden-mention: the message says no recipient was supplied"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_unbidden_mention"]' "$row" \
  "unbidden-mention: named on the metrics row"
assert_contains '"checks_run":2' "$row" \
  "unbidden-mention: counted in checks_run beside the default echo check"

# A negative case has to prove the check RAN and passed, not that the call
# fell over before reaching it: a bare not-contains would pass on a recipe
# whose generation failed, which is how an assertion passes for the wrong
# reason. Every case below asserts the row's own counters too.
assert_check_clean() { # $1 = stderr, $2 = name
  assert_not_contains "no_unbidden_mention" "$1" "$2"
  local r; r=$(tail -1 "$metrics")
  assert_contains '"checks_run":2' "$r" "$2 (the check ran)"
  assert_contains '"checks_failed":0' "$r" "$2 (and passed)"
}

# 53b. The supplied recipient may be mentioned, with or without the `@` in
# the var, and nothing is flagged.
: > "$metrics"
make_mock_curl_think "$tmp" '@nneul, thanks for the report. The crash is at src/main.js:412.'
out=$(run_um nneul)
assert_check_clean "$out" "unbidden-mention: the supplied recipient may be mentioned"
: > "$metrics"
out=$(run_um '@nneul')
assert_check_clean "$out" "unbidden-mention: the recipient var may carry its own @"
: > "$metrics"
make_mock_curl_think "$tmp" '@NNeul, thanks for the report.'
out=$(run_um nneul)
assert_check_clean "$out" "unbidden-mention: handles compare case-insensitively, as the forges resolve them"

# 53c. A third party beside the recipient is still unbidden.
: > "$metrics"
make_mock_curl_think "$tmp" '@nneul, thanks. cc @tomgunning who filed the original.'
out=$(run_um nneul)
assert_contains "check 'no_unbidden_mention' FAILED" "$out" \
  "unbidden-mention: a third party beside the recipient is caught"
assert_contains 'the only handle you supplied is @nneul' "$out" \
  "unbidden-mention: the message names the one permitted handle"

# 53d. Not mentions: a decorator inside a fenced block or an inline code
# span, an email address, a scoped package.
: > "$metrics"
make_mock_curl_think "$tmp" 'The guard is a decorator:\n\n```python\n@property\ndef x(self): ...\n```\n\nReported by tomgunning.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: a decorator inside a fenced block is not a mention"
: > "$metrics"
make_mock_curl_think "$tmp" 'The guard is a decorator:\n\n~~~python\n@property\ndef x(self): ...\n~~~\n\nReported by tomgunning.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: a decorator inside a tilde fence is not a mention"
: > "$metrics"
make_mock_curl_think "$tmp" 'Quoted as sent:\n\n````markdown\n```python\n@property\n```\n@override\n````\n\nReported by tomgunning.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: a nested fence does not close a longer one early"
: > "$metrics"
make_mock_curl_think "$tmp" 'The `@override` annotation is the one to copy.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: an annotation in an inline code span is not a mention"
: > "$metrics"
make_mock_curl_think "$tmp" 'Mail the report to releases@example.com when the branch lands.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: an email address is not a mention"
: > "$metrics"
make_mock_curl_think "$tmp" 'Pin @scope/pkg to the patched release before merging.'
out=$(run_um)
assert_check_clean "$out" "unbidden-mention: a scoped package is not a mention"

# 53d2. A fence that never closes is not a block: truncated output often
# leaves one, and a mention after it must still be seen.
: > "$metrics"
make_mock_curl_think "$tmp" 'Thanks for the report.\n\n```\nsee above\n@tomgunning, see above'
out=$(run_um)
assert_contains "check 'no_unbidden_mention' FAILED" "$out" \
  "unbidden-mention: a mention after an unclosed fence is still caught"

# 53d3. A key passed twice keeps its first value, the one the template
# substituted, so that handle is the permitted one.
: > "$metrics"
make_mock_curl_think "$tmp" '@nneul, thanks for the report.'
out=$(printf '%s\n' "$um_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe um --var recipient=nneul --var recipient=other prose "go" 2>&1 >/dev/null)
assert_check_clean "$out" "unbidden-mention: a repeated recipient var permits its first value"

# 53d4. A mention the caller supplied verbatim in another --var (a lead, an
# opener, a sign-off) is the caller's; a bystander beside it is still not.
{ printf -- '---\ntier: prose\ninputs:\n  stdin: string\n  recipient: string?\n  signoff: string?\nchecks:\n  no_unbidden_mention: recipient\n---\n'
  printf '# um_lead\n\n## When to use\nn/a\n\n## Prompt template\n\n```\nReply using only the facts below.\n\n=== RECIPIENT ===\n{{recipient}}\n\n=== SIGNOFF ===\n{{signoff}}\n\n=== FACTS ===\n{{stdin}}\n```\n\n## Calibration notes\nn/a\n'; } > "$prompts/um_lead.md"
run_um_lead() {
  printf '%s\n' "$um_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
    bash "$SCRIPT" --recipe um_lead --var 'signoff=cc @IsmaelMartinez' prose "go" 2>&1 >/dev/null
}
: > "$metrics"
make_mock_curl_think "$tmp" 'Thanks for the report. cc @IsmaelMartinez'
out=$(run_um_lead)
assert_check_clean "$out" "unbidden-mention: a mention the caller supplied in another var is permitted"
: > "$metrics"
make_mock_curl_think "$tmp" '@tomgunning, thanks for the report. cc @IsmaelMartinez'
out=$(run_um_lead)
assert_contains "check 'no_unbidden_mention' FAILED" "$out" \
  "unbidden-mention: a caller-supplied mention does not excuse a bystander"
assert_not_contains '@ismaelmartinez' "$out" \
  "unbidden-mention: only the bystander is named, not the caller's handle"

# 53e. Undeclared is off: a recipe that does not name the var never runs it.
{ printf -- '---\ntier: prose\nchecks:\n  no_padding_tail: true\n---\n'
  printf '# um_off\n\n## When to use\nn/a\n\n## Prompt template\n\n```\nReply.\n\n{{stdin}}\n```\n\n## Calibration notes\nn/a\n'; } > "$prompts/um_off.md"
: > "$metrics"
make_mock_curl_think "$tmp" '@tomgunning, thanks for the report.'
out=$(printf '%s\n' "$um_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe um_off prose "go" 2>&1 >/dev/null)
assert_not_contains "no_unbidden_mention" "$out" \
  "unbidden-mention: a recipe that does not declare it never runs it"

# 53f. The retry carries the constraint, so the second generation is told
# what to remove rather than being asked again.
: > "$metrics"
make_mock_curl_think "$tmp" '@tomgunning, thanks for the report.'
out=$(printf '%s\n' "$um_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe um prose "go" 2>&1 >/dev/null)
assert_contains "regenerating once" "$out" \
  "unbidden-mention: a failed mention check earns the one retry"
row=$(tail -1 "$metrics")
assert_contains '"retried":true' "$row" \
  "unbidden-mention: the retry is recorded on the row"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
