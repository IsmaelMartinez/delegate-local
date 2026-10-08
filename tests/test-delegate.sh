#!/usr/bin/env bash
# Unit tests for scripts/delegate.sh. Mocks `curl` on a restricted PATH so the
# run is the same on a machine with a live model server.

set -u

# shellcheck source=lib/assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
SCRIPT="$REPO/scripts/delegate.sh"

# fresh — a new $tmp (where the mock curl goes), $prompts inside it and an
# empty $metrics for a section, with no $recipe_stdin. All of it sits under
# the lib's TMPDIR, so nothing needs removing by hand.
fresh() { tmp=$(mktemp -d); prompts="$tmp/prompts"; mkdir -p "$prompts"; metrics=$(mktemp); unset recipe_stdin; }

# mk_check_recipe NAME CHECKS [TEMPLATE] [FRONTMATTER] — write $prompts/NAME.md
# with `tier: prose`, the FRONTMATTER lines as given, CHECKS (one `key: value`
# per line) under `checks:` when non-empty, and TEMPLATE (default GO) as the
# prompt template.
mk_check_recipe() {
  local name="$1" checks="$2" template="${3:-GO}" fm="${4:-}"
  { printf -- '---\ntier: prose\n'
    [[ -n "$fm" ]] && printf '%s\n' "$fm"
    [[ -n "$checks" ]] && printf 'checks:\n%s\n' "$(printf '%s\n' "$checks" | sed 's/^/  /')"
    printf -- '---\n# %s\n\n## Prompt template\n\n```\n%s\n```\n' "$name" "$template"
  } > "$prompts/$name.md"
}

# run_recipe [ENV=VALUE ...] NAME [ARG ...] — delegate.sh --recipe NAME ARG...
# prose go against the mock in $tmp, with $metrics, $prompts, no canary and
# each ENV=VALUE. stdin is $recipe_stdin plus a newline when that is set,
# /dev/null otherwise. Prints stderr; stdout lands in $tmp/stdout. Returns
# delegate.sh's exit status.
run_recipe() {
  local envs=() name
  while [[ "${1:-}" == [A-Z]*=* ]]; do envs+=("$1"); shift; done
  name="$1"; shift
  _run_recipe() {
    env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
      DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$prompts" ${envs[@]+"${envs[@]}"} \
      bash "$SCRIPT" --recipe "$name" "$@" prose go 2>&1 >"$tmp/stdout"
  }
  if [[ -n "${recipe_stdin+set}" ]]; then printf '%s\n' "$recipe_stdin" | _run_recipe "$@"
  else _run_recipe "$@" </dev/null; fi
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
mock_curl "$tmp" "" "$sniff"
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
  assert_not_contains '"top_p"' "$payload" "payload: bare greedy omits top_p"
  assert_not_contains '"top_k"' "$payload" "payload: bare greedy omits top_k"
  assert_not_contains '"presence_penalty"' "$payload" "payload: bare greedy omits presence_penalty"
else
  echo "  FAIL  payload sniff: file empty"; fail=$((fail+1))
fi
# A bare call writes no sampling_* keys to the row.
assert_not_contains '"sampling_temperature"' "$line" "metrics: bare greedy omits sampling_temperature"
assert_not_contains '"sampling_top_p"' "$line" "metrics: bare greedy omits sampling_top_p"

# 3. Opt-out env var suppresses metrics writing.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); rm -f "$metrics"  # ensure file does not exist
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "opt-out: still exits 0"
assert_false "opt-out: metrics file not created" test -f "$metrics"

# 3b. The legacy DELEGATE_TO_OLLAMA_* names are no longer read (#567): the row
# is written and the meta line and the verdict reminder printed although the
# three opt-outs are set.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); rm -f "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_NO_METRICS=1 DELEGATE_TO_OLLAMA_NO_META=1 \
  DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "legacy alias: exits 0"
assert_eq 1 "$(cat "$metrics" 2>/dev/null | grep -c '"source":"delegate"')" "legacy alias: DELEGATE_TO_OLLAMA_NO_METRICS is ignored"
assert_contains "delegate-meta:" "$out" "legacy alias: DELEGATE_TO_OLLAMA_NO_META is ignored"
assert_contains "record verdict" "$out" "legacy alias: DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE is ignored"

# 3c. The legacy fd name is not validated either: an FD of 0, which the
# DELEGATE_LOCAL_ name refuses with exit 2, leaves the reminder on stderr.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); rm -f "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD=0 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "legacy alias: DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD=0 is not validated"
assert_contains "record verdict" "$(cat "$stderr_file")" "legacy alias: the reminder stays on stderr"

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

# 5. Stdin context is included in metrics char count.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash -c 'echo "context-text-here" | bash "$0" prose "Summarise"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin context: exits 0"
line=$(cat "$metrics")
# "context-text-here\n" through cat stripping the trailing newline is 17 chars.
assert_contains '"context_chars":17' "$line" "metrics: context_chars counted"

# 6. DELEGATE_THINK=true overrides default false in payload.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=true \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true: exits 0"
assert_contains '"enable_thinking":true' "$(cat "$sniff")" "payload: enable_thinking:true when overridden"

# 6b. DELEGATE_THINK with a non-boolean stray value is normalised to false
# (so a jq parse error can't kill the delegation).
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=yes \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=yes (non-boolean): still exits 0"
assert_contains '"enable_thinking":false' "$(cat "$sniff")" "payload: non-boolean DELEGATE_THINK normalises to false"

# 7. HTTP failure (curl non-zero) propagates and is logged.
tmp=$(mktemp -d)
make_mock_curl_fail "$tmp"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_true "HTTP failure -> non-zero exit" test "$EC" -ne 0
assert_contains '"exit_status":7' "$(cat "$metrics")" "metrics: HTTP failure exit_status logged"

# 8. --recipe NAME prepends the '## Prompt template' fenced block of
# prompts/NAME.md, substitutes --var values into {{key}}, and tags the row.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 9. --recipe with an unknown name fails with a clear error and exit 2.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe missing prose "p" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe missing -> exit 2"
assert_contains "not found" "$out" "--recipe missing: error mentions not found"

# 10. Unsubstituted placeholders are a hard error (exit 2, names listed).
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 11. {{stdin}} placeholder is substituted with piped stdin content; the
# stdin is NOT also appended after the recipe (would otherwise duplicate).
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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
assert_eq 1 "$(grep -o 'first' "$sniff" | wc -l | tr -d ' ')" "--recipe: stdin not duplicated when {{stdin}} marker used"

# 12. --recipe makes the prompt arg optional (recipe carries the instruction).
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 13. --var value containing newlines and special punctuation survives
# substitution intact (argv-driven, not shell-re-evaluated).
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 13a. `&` in a --var value or the piped context is literal (#547). bash 5.2
# turns on patsub_replacement, where `&` in a ${t//pat/rep} replacement means
# the matched text, so `R&D` rendered as `R{{lead}}D`. macOS bash 3.2 has no
# such option, so on it this passes with or without the fix.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 14. --var without '=' is rejected.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 14a. --var key with glob metacharacters is rejected: the key goes into a
# bash pattern replacement, where it would match wider than the literal {{key}}.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 14b. --var key that is a plain identifier (letters, digits, underscore)
# still substitutes normally after the key-shape guard.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 15. A --var value containing {{...}} must not trip the unsubstituted-
# placeholder guard, which checks the template's placeholders, not the result.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 16. A markdown heading inside the fenced block must not end the section.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 17. prompt_chars includes the recipe template length.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 17b. A {{stdin}} recipe folds the context into the template; prompt_chars
# counts only the template around it, so estimated_tokens_avoided does not
# count the context twice (#550).
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/wrap.md" <<'EOF'
# wrap

## When to use
Test.

## Prompt template

```
PRE {{stdin}} POST
```

## Calibration notes
n/a
EOF
EC=0
head -c 4000 /dev/zero | tr '\0' 'x' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe wrap prose >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "{{stdin}} metric: exits 0"
line=$(cat "$metrics")
# "PRE  POST" is 9 chars; the 4000 piped chars are context_chars only.
assert_eq "9|4000" "$(printf '%s' "$line" | jq -r '"\(.prompt_chars)|\(.context_chars)"')" \
  "{{stdin}} metric: prompt_chars excludes the substituted context"
assert_eq "$(( (9 + 4000 + $(printf '%s' "$line" | jq -r '.output_chars')) / 4 ))" \
  "$(printf '%s' "$line" | jq -r '.estimated_tokens_avoided')" \
  "{{stdin}} metric: estimated_tokens_avoided counts the context once"

# 12. MLX: dispatches to /v1/chat/completions, parses
# .choices[0].message.content, and tags the metrics line with backend:"mlx".
# 12a. Happy path with the MLX backend.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
argv_sniff="$tmp/argv.txt"
MOCK_MODELS='mlx-community/Qwen3.6-35B-A3B-Instruct-4bit'
mock_curl "$tmp" 'mlx-output-ok' "$payload_sniff" "$argv_sniff"
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
assert_not_contains "/api/generate" "$argv" "MLX dispatch does not hit /api/generate"
assert_not_contains "/v1/completions" "$argv" "MLX dispatch does not hit raw /v1/completions"
# enable_thinking:false mirrors Ollama's think:false so the answer lands in
# .content rather than .reasoning.
payload=$(cat "$payload_sniff")
assert_contains '"model":"mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"' "$payload" "MLX payload: model field"
assert_contains '"max_tokens":' "$payload" "MLX payload: max_tokens (OpenAI shape)"
assert_contains '"temperature":0' "$payload" "MLX payload: bare greedy temperature=0"
assert_not_contains '"top_p"' "$payload" "MLX payload: bare greedy omits top_p"
assert_not_contains '"top_k"' "$payload" "MLX payload: bare greedy omits top_k"
assert_not_contains '"presence_penalty"' "$payload" "MLX payload: bare greedy omits presence_penalty"
assert_contains '"messages":' "$payload" "MLX payload: messages array (chat-completions shape)"
assert_contains '"role":"user"' "$payload" "MLX payload: user-role message"
assert_contains '"enable_thinking":false' "$payload" "MLX payload: enable_thinking:false by default (mirrors Ollama think:false)"
assert_not_contains '"think":' "$payload" "MLX payload omits Ollama-only think field"
assert_not_contains '"prompt":' "$payload" "MLX payload omits raw prompt field"

# 12d. MLX_HOST override is honoured by the dispatch URL.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
mock_curl "$tmp" 'mlx-output-ok' "/dev/null" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  MLX_HOST="http://10.0.0.5:9999" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX_HOST override: exits 0"
assert_contains "http://10.0.0.5:9999/v1/chat/completions" "$(cat "$argv_sniff")" "MLX_HOST override applied to curl URL"

# 12e. DELEGATE_MAX_TOKENS overrides the MLX max_tokens default.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
mock_curl "$tmp" 'mlx-output-ok' "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_MAX_TOKENS=16384 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_MAX_TOKENS override: exits 0"
assert_contains '"max_tokens":16384' "$(cat "$payload_sniff")" "DELEGATE_MAX_TOKENS override flows into payload"

# 12e1. A non-numeric DELEGATE_MAX_TOKENS is refused up front (#547): `4k`
# used to make jq --argjson fail and curl post an empty body.
tmp=$(mktemp -d)
mock_curl "$tmp" 'mlx-output-ok'
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
  mock_curl "$tmp" 'mlx-output-ok'
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
mock_curl "$tmp" 'mlx-output-ok' "$payload_sniff" "$argv_sniff"
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

# 12e3. An empty payload is refused before dispatch with its own message and
# a failure row, never posted as a 0-byte body that reads as a daemon problem.
# A jq shim fails only on the chat-payload build.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
mock_curl "$tmp" 'mlx-output-ok' "/dev/null" "$argv_sniff"
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

# 12f. DELEGATE_THINK=true on MLX flips chat_template_kwargs.enable_thinking.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
mock_curl "$tmp" 'mlx-output-ok' "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_THINK=true \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true on MLX: exits 0"
assert_contains '"enable_thinking":true' "$(cat "$payload_sniff")" "DELEGATE_THINK=true flips enable_thinking on for MLX"

# 13. A model name with an embedded double quote still yields valid JSON:
# pick-model returns whatever a provider reports.
tmp=$(mktemp -d)
MOCK_MODELS='qwen3.6:35b"weird-name'
mock_curl "$tmp"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "jq-metrics: weird model name still exits 0"
line=$(cat "$metrics")
assert_true "jq-metrics: line is valid JSON despite embedded quote in model" jq -e . <<< "$line"
decoded_model=$(echo "$line" | jq -r '.model')
assert_eq 'qwen3.6:35b"weird-name' "$decoded_model" "jq-metrics: model field decodes to original string"

# 14. Verdict nudge prints to stderr on a successful call.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_lacks ',| \| | or ' "$nudge_cmds" "verdict-nudge: no command line joins alternatives with ',', '|' or 'or'"
# One tier (ADR 0030): there is no human taste judgment to drop the flag for.
assert_lacks 'drop --source|taste judgment' "$stderr_content" "verdict-nudge: no human-tier hand-off"
# stdout holds only the model output so downstream pipes keep working.
assert_not_contains "record verdict" "$out" "verdict-nudge: stdout unaffected"

# 14a. A non-TTY caller still gets the nudge (#149): a `[[ -t 2 ]]` gate would
# silence it for Agent SDK tool calls, routines and `2>logfile` redirects.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 15. DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 silences the nudge but keeps
# the rest of the behaviour intact (metrics row still written, model
# output still on stdout). For users who genuinely don't want the noise.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge opt-out: still exits 0"
stderr_content=$(cat "$stderr_file")
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge opt-out: silenced"
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge opt-out: metrics row still written"

# 16. NO_METRICS=1 also silences the nudge: there is no row to verdict.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); rm -f "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge NO_METRICS: still exits 0"
stderr_content=$(cat "$stderr_file")
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge NO_METRICS: silenced"

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
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge on failure: silenced"

# 17a. DELEGATE_LOCAL_VERDICT_NUDGE_FD=N redirects the nudge to fd N, for
# callers that capture 2>&1 and want stderr clean (#139).

# 17a-1. fd 3 redirected to a file: nudge lands there, not on fd 2.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge FD=3: fd 2 stays clean"
assert_contains "delegate: record verdict" "$nudge_content" "verdict-nudge FD=3: nudge lands on fd 3"
assert_not_contains "record verdict" "$out" "verdict-nudge FD=3: stdout unaffected"

# 17a-2. fd 3 set but not redirected: the call still succeeds and the failed
# write is absorbed, so no "Bad file descriptor" lands on the fd 2 the caller
# wanted clean.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=3 no redirect: still exits 0"
stderr_content=$(cat "$stderr_file")
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge FD=3 no redirect: fd 2 stays clean"
assert_false "verdict-nudge FD=3 no redirect: failed write absorbed silently" grep -qi "bad file descriptor" <<< "$stderr_content"
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge FD=3 no redirect: metrics row still written"

# 17a-3. An explicit FD=2 behaves like unset.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 17a-4. FD=1 is allowed: the nudge lands inline on stdout.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge FD=1: exits 0"
assert_contains "record verdict" "$out" "verdict-nudge FD=1: nudge lands on stdout"
stderr_content=$(cat "$stderr_file")
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge FD=1: fd 2 stays clean"

# 17a-5. FD=0 is rejected with exit 2 before the model is contacted.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_false "verdict-nudge FD=0: no metrics row (rejection fires pre-flight)" test -s "$metrics"

# 17a-6. FD=foo (non-numeric) is rejected. exit 2.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 17a-7. FD=-1 (negative) is rejected.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=-1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=-1: exits 2 (negative rejected)"

# 17a-7b. FD=10 (multi-digit) is rejected: bash 3.2 has no reliable `>&$N`
# for N>=10, so the validation fails loud rather than the write failing silently.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 17a-7c. FD=99 is also rejected.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_VERDICT_NUDGE_FD=99 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "verdict-nudge FD=99: exits 2 (multi-digit rejected)"

# 17a-8. FD set and NO_VERDICT_NUDGE=1: suppression beats redirect.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_eq "" "$(cat "$nudge_file")" "verdict-nudge FD=3 + NO_VERDICT_NUDGE: NO_VERDICT_NUDGE wins (no nudge on fd 3)"
stderr_content=$(cat "$stderr_file")
assert_not_contains "record verdict" "$stderr_content" "verdict-nudge FD=3 + NO_VERDICT_NUDGE: fd 2 also stays clean"

# 17a-9. FD set and NO_METRICS=1: no row, so no nudge.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_eq "" "$(cat "$nudge_file")" "verdict-nudge FD=3 + NO_METRICS: NO_METRICS wins (no nudge on fd 3)"

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
assert_eq "" "$(cat "$nudge_file")" "verdict-nudge FD=3 on failure: silenced"

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
assert_false "canary timeout: dispatch sniff stays empty" test -s "$sniff"
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
assert_not_contains "record verdict" "$stderr_content" "canary timeout: verdict nudge silenced"

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
assert_not_contains "did not return within" "$stderr_content" "canary refused: timeout copy not used"
assert_contains '"exit_status":3' "$(cat "$metrics")" "canary refused: metrics row tagged status:3"

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
assert_not_contains "did not return within" "$stderr_content" "canary http_error: timeout copy not used"
assert_contains '"exit_status":3' "$(cat "$metrics")" "canary http_error: metrics row tagged status:3"

# 19. The delegate-meta stderr line is the contract surface SKILL.md teaches
# the assistant to read.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_not_contains "delegate-meta:" "$out" "delegate-meta: stdout unaffected"
# tokens_local is (prompt + context + output chars) / 4, compared numerically.
meta_line=$(grep '^delegate-meta:' "$stderr_file")
tokens_val=$(printf '%s' "$meta_line" | grep -oE 'tokens_local=[0-9]+' | cut -d= -f2)
assert_true "delegate-meta: tokens_local is a non-negative integer ($tokens_val)" grep -qE '^[0-9]+$' <<< "$tokens_val"

# 19a. The meta line names the row it wrote so the nudge can hand the pin
# back (#474). The value must be the row's ts byte for byte: a reformatted
# or re-read clock matches no row.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>"$stderr_file"
row_ts=$(jq -r '.ts' "$metrics")
assert_true "delegate-meta ts: the metrics row carries an ISO 8601 ts ($row_ts)" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<< "$row_ts"
meta_ts=$(grep '^delegate-meta:' "$stderr_file" | grep -oE 'ts="[^"]*"' | cut -d'"' -f2)
assert_eq "$row_ts" "$meta_ts" "delegate-meta ts: ts field is the metrics row's ts, byte for byte"
# ts is second-precision and parallel delegations share it, so the pin is the
# row's otel_span_id (16 hex, generated on every row).
row_id=$(jq -r '.otel_span_id' "$metrics")
assert_true "delegate-meta id: the metrics row carries a 16-hex otel_span_id ($row_id)" grep -qE '^[0-9a-f]{16}$' <<< "$row_id"
meta_id=$(grep '^delegate-meta:' "$stderr_file" | grep -oE 'id="[^"]*"' | cut -d'"' -f2)
assert_eq "$row_id" "$meta_id" "delegate-meta id: id field is the metrics row's otel_span_id, byte for byte"
assert_contains "--id $row_id " "$(grep 'record verdict' "$stderr_file")" \
  "verdict-nudge: the copyable command already carries --id with the row's span id"

# 19c. A row that could not be appended is not a row: the call still
# succeeds, but the meta line names no ts/id and nothing nudges for a verdict.
tmp=$(mktemp -d)
mock_curl "$tmp"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE=/dev/null/metrics.jsonl \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta unwritable: the delegation still succeeds"
assert_contains "mock-model-output" "$out" "delegate-meta unwritable: model output still on stdout"
meta_line=$(grep '^delegate-meta:' "$stderr_file")
assert_contains 'model="' "$meta_line" "delegate-meta unwritable: meta line still printed"
assert_lacks ' (ts|id)="' "$meta_line" "delegate-meta unwritable: no ts/id when the append failed"
assert_not_contains 'record verdict' "$(cat "$stderr_file")" "delegate-meta unwritable: no verdict nudge when the append failed"

# 19d. The row carries CLAUDE_CODE_SESSION_ID so the hooks can scope a
# projectless lookup to the session (#476): present when set, absent when
# unset, never an empty string.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 19b. With metrics off there is no row, so the meta line names no ts: a
# value that matches nothing would only send the caller to a --ts refusal.
tmp=$(mktemp -d)
mock_curl "$tmp"
stderr_file=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>"$stderr_file"
meta_line=$(grep '^delegate-meta:' "$stderr_file")
assert_contains 'model="' "$meta_line" "delegate-meta ts: meta line still printed with metrics off"
assert_not_contains ' ts="' "$meta_line" "delegate-meta ts: no ts field when no row was written"

# 20. DELEGATE_LOCAL_NO_META=1 silences the meta line only; the nudge and
# the metrics row are unaffected.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_META=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta opt-out: still exits 0"
stderr_content=$(cat "$stderr_file")
assert_not_contains "delegate-meta:" "$stderr_content" "delegate-meta opt-out: silenced"
assert_contains "record verdict" "$stderr_content" "delegate-meta opt-out: verdict nudge unaffected"
assert_eq 1 "$(grep -c '^' "$metrics")" "delegate-meta opt-out: metrics row still written"

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
assert_not_contains "delegate-meta:" "$stderr_content" "delegate-meta on failure: silenced"

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

# 23. Stdin probe (#169): `[[ ! -t 0 ]]` is true for an empty unix socket and
# `cat` then blocks forever; the probe is `-p /dev/stdin || -s /dev/stdin`.

# 23a. </dev/null: not a pipe, holds no data, so cat is skipped.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  perl -e 'alarm 5; exec @ARGV' \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin probe: </dev/null exits 0 (no hang)"
assert_contains '"context_chars":0' "$(cat "$metrics")" "stdin probe: </dev/null skips cat (context_chars=0)"

# 23b. Piped stdin still works, under the perl alarm to assert no hang.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  perl -e 'alarm 5; exec @ARGV' \
  bash -c 'printf "%s" "piped-data" | bash "$0" prose "Summarise"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin probe: piped data exits 0"
assert_contains '"context_chars":10' "$(cat "$metrics")" "stdin probe: piped data captured (10 chars)"

# 23c. An empty AF_UNIX socket as stdin, the other end held open and never
# written: the alarm exits 142 if cat blocks.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 24. Queue-wait / generation split (#170): queue_wait_ms + generation_ms ==
# duration_ms is the contract downstream consumers rely on.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_true "queue-wait split: queue_wait_ms is a non-negative integer ($qwait_val)" grep -qE '^[0-9]+$' <<< "$qwait_val"
assert_true "queue-wait split: generation_ms is a non-negative integer ($gen_val)" grep -qE '^[0-9]+$' <<< "$gen_val"
assert_eq "$dur_val" "$((qwait_val + gen_val))" "queue-wait split: queue_wait_ms + generation_ms == duration_ms ($qwait_val + $gen_val == $dur_val)"
# Exactly 1 proves the float-to-int path ran, not the empty-string-to-zero fallback.
assert_eq 1 "$qwait_val" "queue-wait split: synthetic 0.001s TTFB → 1 ms queue_wait_ms"

# 25. On a failed dispatch queue_wait_ms is 0 and generation_ms absorbs the
# whole duration, so the sum invariant still holds.
tmp=$(mktemp -d)
make_mock_curl_fail "$tmp"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_true "queue-wait split on failure: non-zero exit" test "$EC" -ne 0
line=$(cat "$metrics")
qwait_val=$(echo "$line" | jq -r '.queue_wait_ms')
gen_val=$(echo "$line" | jq -r '.generation_ms')
dur_val=$(echo "$line" | jq -r '.duration_ms')
assert_eq 0 "$qwait_val" "queue-wait split on failure: queue_wait_ms is 0"
assert_eq "$dur_val" "$((qwait_val + gen_val))" "queue-wait split on failure: sum-equals-duration invariant holds ($qwait_val + $gen_val == $dur_val)"

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
mock_curl "$tmp"
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

# 27b. Required --var missing → exit 2 with clear error listing missing key.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27c. --var integer fails type check → exit 2 with key/type/value named.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27d. Optional `string?` --var missing → success (lazy migration friendly).
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27d2. An optional input with a placeholder in the body, --var provided:
# the value is substituted.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 27d3. The same recipe with the optional --var omitted: the placeholder is
# blanked rather than tripping the unsubstituted-placeholder guard.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 27e. No inputs: block: no type check runs.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27f. An undeclared --var passes through untouched.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27g. An optional `integer?` that is present is still type-checked.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27h. An unsupported type in inputs: is a recipe authoring error, exit 2.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27i. Negative integer is accepted (real-world: error codes, offsets).
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 27j. Piped stdin satisfies a declared `stdin: string` input.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 23k. stdin: integer type-checks the piped value.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 23l. The missing-required error has no trailing space.
tmp=$(mktemp -d)
mock_curl "$tmp"
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
assert_eq "${first_line% }" "$first_line" "inputs: missing-required error has no trailing whitespace"

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
assert_true "OT2: body parses as JSON" jq -e . <<< "$otel_body"
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
assert_true "OT2: trace_id is 32 hex chars" grep -qE '^[0-9a-f]{32}$' <<< "$trace_in_otel"
assert_true "OT2: span_id is 16 hex chars" grep -qE '^[0-9a-f]{16}$' <<< "$span_in_otel"
# No-content rule (ADR 0007): no prompt or output text on the span.
assert_not_contains 'gen_ai.prompt' "$otel_body" "OT2: body has no gen_ai.prompt"
assert_not_contains 'gen_ai.completion' "$otel_body" "OT2: body has no gen_ai.completion"
assert_lacks 'delegate\.prompt_text|delegate\.output_text|delegate\.context_text' "$otel_body" "OT2: body has no content-bearing delegate.* attributes"

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
assert_not_contains "OTLP export failed" "$stderr_content" "OT10: default-verbose is silent on OTLP failure"

# OT11. trace_id / span_id are written to the row even with the exporter
# unset, so a later feedback span can still link to it.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT11: endpoint unset → exits 0"
line=$(cat "$metrics")
assert_contains '"otel_trace_id":"' "$line" "OT11: metrics row carries otel_trace_id even with exporter unset"
assert_contains '"otel_span_id":"' "$line" "OT11: metrics row carries otel_span_id even with exporter unset"

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
assert_not_contains '"delegate.prompt"' "$otel_body" "OT14: delegate.prompt key absent by default"
assert_not_contains '"delegate.context"' "$otel_body" "OT14: delegate.context key absent by default"
assert_not_contains '"delegate.output"' "$otel_body" "OT14: delegate.output key absent by default"
assert_not_contains "$SENTINEL_PROMPT" "$otel_body" "OT14: prompt sentinel text omitted from body"
assert_not_contains "$SENTINEL_CONTEXT" "$otel_body" "OT14: context sentinel text omitted from body"
assert_not_contains 'mock-model-output: ok' "$otel_body" "OT14: model output text omitted from body"
# The schema is omission, not a placeholder.
assert_not_contains '<redacted>' "$otel_body" "OT14: no '<redacted>' sentinel in body (omission, not placeholder)"

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
assert_lacks '"delegate\.prompt"|ExplicitZeroSentinel' "$otel_body" "OT16: DELEGATE_OTEL_INCLUDE_CONTENT=0 redacts same as unset"

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
assert_lacks '"delegate\.prompt"|TrueSentinelValue' "$otel_body" "OT17: only literal '1' enables include-content (typo-safe)"

# --- Sampler override (#193, #567): greedy for every model by default;
# DELEGATE_TEMPERATURE is the one opt-in, and the row carries
# sampling_temperature only when the caller set it ---

# QS1. A Qwen model with no overrides is greedy on the payload and the row.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS1: Qwen model with no overrides exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0' "$payload" "QS1: bare greedy payload has temperature:0"
assert_not_contains '"temperature":0.7' "$payload" "QS1: Qwen model stays greedy by default"
assert_not_contains '"top_p"' "$payload" "QS1: bare invocation omits top_p"
assert_not_contains '"top_k"' "$payload" "QS1: bare invocation omits top_k"
assert_not_contains '"presence_penalty"' "$payload" "QS1: bare invocation omits presence_penalty"
line=$(cat "$metrics")
assert_not_contains '"sampling_temperature"' "$line" "QS1: bare metrics row omits sampling_temperature"
assert_not_contains '"sampling_top_p"' "$line" "QS1: bare metrics row omits sampling_top_p"
assert_not_contains '"sampling_top_k"' "$line" "QS1: bare metrics row omits sampling_top_k"
assert_not_contains '"sampling_presence_penalty"' "$line" "QS1: bare metrics row omits sampling_presence_penalty"

# QS2. A non-Qwen model is greedy by default too.
tmp=$(mktemp -d)
MOCK_MODELS='gemma4:latest'
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
MOCK_MODELS='qwen3.6:35b-a3b'
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS2: non-Qwen model exits 0"
payload=$(cat "$sniff")
assert_contains '"model":"gemma4:latest"' "$payload" "QS2: model resolved to gemma4"
assert_contains '"temperature":0' "$payload" "QS2: non-Qwen payload has bare temperature:0"
assert_not_contains '"top_p"' "$payload" "QS2: non-Qwen payload omits top_p"
assert_not_contains '"top_k"' "$payload" "QS2: non-Qwen payload omits top_k"
assert_not_contains '"presence_penalty"' "$payload" "QS2: non-Qwen payload omits presence_penalty"
line=$(cat "$metrics")
assert_not_contains '"sampling_temperature"' "$line" "QS2: bare metrics row omits sampling_temperature"

# QS3. DELEGATE_TEMPERATURE reaches the payload and the row; the three
# sampler vars #567 removed are ignored even when set.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.7 \
  DELEGATE_TOP_P=0.8 \
  DELEGATE_TOP_K=20 \
  DELEGATE_PRESENCE_PENALTY=1.3 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS3: temperature opt-in exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0.7' "$payload" "QS3: opt-in payload carries temperature=0.7"
assert_not_contains '"top_p"' "$payload" "QS3: DELEGATE_TOP_P is no longer read"
assert_not_contains '"top_k"' "$payload" "QS3: DELEGATE_TOP_K is no longer read"
assert_not_contains '"presence_penalty"' "$payload" "QS3: DELEGATE_PRESENCE_PENALTY is no longer read"
line=$(cat "$metrics")
assert_contains '"sampling_temperature":0.7' "$line" "QS3: opt-in metrics row carries sampling_temperature"
assert_not_contains '"sampling_top_p"' "$line" "QS3: the row has no sampling_top_p"
assert_not_contains '"sampling_top_k"' "$line" "QS3: the row has no sampling_top_k"
assert_not_contains '"sampling_presence_penalty"' "$line" "QS3: the row has no sampling_presence_penalty"

# QS3b. Only DELEGATE_TEMPERATURE set: the others stay off the payload and the row.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.5 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS3b: partial opt-in exits 0"
payload=$(cat "$sniff")
assert_contains '"temperature":0.5' "$payload" "QS3b: partial opt-in payload carries the override"
assert_not_contains '"top_p"' "$payload" "QS3b: partial opt-in omits top_p"
line=$(cat "$metrics")
assert_contains '"sampling_temperature":0.5' "$line" "QS3b: partial opt-in metrics row carries sampling_temperature"
assert_not_contains '"sampling_top_p"' "$line" "QS3b: partial opt-in metrics omits sampling_top_p"

# QS4. Non-numeric DELEGATE_TEMPERATURE exits 2 with a clear stderr.
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# QS4b. The removed vars are not read, so a garbage value is not an error.
for vname in DELEGATE_TOP_P DELEGATE_TOP_K DELEGATE_PRESENCE_PENALTY; do
  tmp=$(mktemp -d)
  mock_curl "$tmp"
  metrics=$(mktemp); : > "$metrics"
  stderr_file=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    "$vname"="garbage" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
  assert_eq 0 "$EC" "QS4b/$vname: ignored (exit 0)"
  assert_not_contains "$vname" "$(cat "$stderr_file")" "QS4b/$vname: stderr does not name it"
  rm -rf "$tmp" "$metrics" "$stderr_file"
done

# QS4c. Shapes a `[!0-9.-]` character class would let through but jq
# --argjson rejects must fail with the validator's own error, not jq's.
for bad in "1-2" "5-" ".-" "1.5.6" "-" "."; do
  tmp=$(mktemp -d)
  mock_curl "$tmp"
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
  mock_curl "$tmp"
  metrics=$(mktemp)
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_TEMPERATURE="$good" \
    bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
  assert_eq 0 "$EC" "QS4d/'$good': accepted (exit 0)"
  rm -rf "$tmp" "$metrics"
done

# QS5. On MLX the override lands as a top-level key (OpenAI shape), not in
# an `options` object.
tmp=$(mktemp -d)
payload_sniff="$tmp/payload.json"
mock_curl "$tmp" 'mlx-output-ok' "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=0.7 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "QS5: MLX + temperature opt-in exits 0"
payload=$(cat "$payload_sniff")
assert_contains '"temperature":0.7' "$payload" "QS5: MLX payload has opt-in temperature"

# QS5b. A non-numeric override exits 2 on MLX too.
tmp=$(mktemp -d)
mock_curl "$tmp" 'mlx-output-ok'
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TEMPERATURE=oops \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 2 "$EC" "QS5b: MLX + bad DELEGATE_TEMPERATURE exits 2"
assert_contains "DELEGATE_TEMPERATURE" "$(cat "$stderr_file")" "QS5b: MLX validator stderr names env var"

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
assert_not_contains '"top_p"' "$canary_payload" "QS6: canary omits top_p"
assert_not_contains '"temperature":0.7' "$canary_payload" "QS6: canary stays greedy"

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
assert_not_contains '"delegate.output"' "$otel_body" "OT18: delegate.output omitted when output_text is empty (consistent with delegate.recipe)"
assert_not_contains '"delegate.context"' "$otel_body" "OT18: delegate.context omitted when context_text is empty"

# 30. DELEGATE_STRIP_THINK strips a leading <think>...</think> trace.

# 30a. Strip on: only the answer reaches stdout.
tmp=$(mktemp -d)
mock_curl "$tmp" '<think>\nLet me work through this carefully.\n</think>\n\nCLEAN_ANSWER_123'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "CLEAN_ANSWER_123" "$out" "strip-think on: only the answer remains, trace removed"

# 30b. Strip OFF (default): the full trace is preserved on stdout.
tmp=$(mktemp -d)
mock_curl "$tmp" '<think>\nLet me work through this carefully.\n</think>\n\nCLEAN_ANSWER_123'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_contains "<think>" "$out" "strip-think off (default): opening trace tag preserved"
assert_contains "CLEAN_ANSWER_123" "$out" "strip-think off: answer still present"

# 30c. Strip ON but response has no </think>: no-op, output unchanged.
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_contains "mock-model-output: ok" "$out" "strip-think on, no </think>: no-op passthrough"

# 30d. A closing </think> with no opening tag (the template-prefilled shape)
# still strips to the answer.
tmp=$(mktemp -d)
mock_curl "$tmp" 'Reasoning emitted with no opening tag.\n</think>\n\nPREFILLED_ANSWER_456'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=1 \
  bash "$SCRIPT" prose "summarise" </dev/null 2>/dev/null)
assert_eq "PREFILLED_ANSWER_456" "$out" "strip-think on: prefilled-open-tag trace stripped to answer"

# 30e. The reasoning tier strips by default.
tmp=$(mktemp -d)
mock_curl "$tmp" '<think>\nreasoning here\n</think>\n\nREASONING_ANSWER_789'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" reasoning "infer something" </dev/null 2>/dev/null)
assert_eq "REASONING_ANSWER_789" "$out" "strip-think: reasoning tier strips by default (no env set)"

# 30f. DELEGATE_STRIP_THINK=0 disables the strip on the reasoning tier.
tmp=$(mktemp -d)
mock_curl "$tmp" '<think>\nreasoning here\n</think>\n\nREASONING_ANSWER_789'
metrics=$(mktemp)
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" DELEGATE_STRIP_THINK=0 \
  bash "$SCRIPT" reasoning "infer something" </dev/null 2>/dev/null)
assert_contains "<think>" "$out" "strip-think: reasoning tier + STRIP_THINK=0 preserves trace"

# 31. Flavor profile (ADR 0013): {{flavor_*}} placeholders come from
# scripts/flavor-defaults.sh unless a per-user profile.sh overrides them.
tmp=$(mktemp -d)
sniff="$tmp/payload.json"
mock_curl "$tmp" "" "$sniff"
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

# 32. Output checks (ADR 0014): a recipe's `checks:` block runs on the final
# output, warns on stderr and puts checks_failed=N on the meta line. What
# each check decides is tests/test-checks.sh; these cases cover the wiring.
fresh
mk_check_recipe chk $'subject_max: 10\nno_padding_tail: true'
# 32a. Both checks fail. The "This-X" padding shape is never auto-stripped,
# so it stays a failure.
mock_curl "$tmp" 'This first line is far longer than ten chars\n\nthe body works fine. This approach ensures simplicity'
out=$(run_recipe chk)
assert_contains "check 'subject_max' FAILED" "$out" "checks: subject_max failure reported on stderr"
assert_contains "check 'no_padding_tail' FAILED" "$out" "checks: no_padding_tail failure reported on stderr"
assert_contains "checks_failed=2" "$out" "checks: failure count rides the delegate-meta line"
# 32a-i. The row names which checks failed, in run order.
assert_contains '"checks_failed_names":["subject_max","no_padding_tail"]' "$(tail -1 "$metrics")" \
  "checks: metrics row names both failed checks in run order"
# 32b. Clean output -> no FAILED warnings, no checks_failed field.
mock_curl "$tmp" 'short\n\nthe body returns a structured response and stops'
assert_lacks "FAILED|checks_failed=" "$(run_recipe chk)" "checks: clean output triggers no check warnings"
# 32c. A participial-comma tail is auto-fixed: stripped, reported as
# AUTO-FIXED, counted as checks_autofixed on the row.
mock_curl "$tmp" 'short\n\nthe body drops the per-call cost, ensuring nothing regresses'
err=$(run_recipe chk); out=$(cat "$tmp/stdout")
assert_contains "check 'no_padding_tail' AUTO-FIXED" "$err" "checks: participial tail auto-fixed (not failed)"
assert_contains "checks_autofixed=1" "$err" "checks: autofix count rides the delegate-meta line"
assert_not_contains "ensuring nothing regresses" "$out" "checks: padding clause stripped from output"
assert_contains "the body drops the per-call cost" "$out" "checks: content before the padding clause is preserved"
assert_contains '"checks_autofixed":1' "$(cat "$metrics")" "checks: checks_autofixed persisted to metrics"
# 32d. DELEGATE_NO_AUTOFIX=1 restores warn-only: the same tail FAILS, not fixed.
out=$(run_recipe DELEGATE_NO_AUTOFIX=1 chk)
assert_contains "check 'no_padding_tail' FAILED" "$out" "checks: DELEGATE_NO_AUTOFIX restores warn-only"
assert_not_contains "AUTO-FIXED" "$out" "checks: NO_AUTOFIX did not strip"

# 33. subject_type takes its value from an optional --var, substituted into
# the checks block, and is skipped when the var is omitted.
mk_check_recipe typ 'subject_type: {{type}}' 'GO {{type}}' $'inputs:\n  type: string?'
# 33c. Provided type the subject ignores -> FAILED.
mock_curl "$tmp" 'feat: did a thing\n\nbody'
assert_contains "check 'subject_type' FAILED" "$(run_recipe typ --var type=fix)" \
  "checks: subject_type flags an ignored --var type override"
# 33d. Provided type the subject honours (with a scope) -> no failure.
mock_curl "$tmp" 'fix(core): did a thing\n\nbody'
assert_not_contains "subject_type' FAILED" "$(run_recipe typ --var type=fix)" \
  "checks: subject_type passes when subject carries the type"
# 33e. Omitted optional type -> placeholder blanked in the checks block, skipped.
mock_curl "$tmp" 'anything goes here\n\nbody'
assert_lacks "subject_type' FAILED|\{\{type\}\}" "$(run_recipe typ)" \
  "checks: subject_type skipped when optional type omitted"
# body_required: fail a subject-only output, pass a subject+body.
mk_check_recipe bodyreq 'body_required: true'
# 33f. Subject-only output (no body) -> body_required FAILED + checks_failed=1.
mock_curl "$tmp" 'feat: a subject with no body'
out=$(run_recipe bodyreq)
assert_contains "check 'body_required' FAILED" "$out" "checks: body_required flags a subject-only output"
assert_contains "checks_failed=1" "$out" "checks: body_required failure rides the delegate-meta line"
# 33g. Subject + blank line + body -> body_required not flagged.
mock_curl "$tmp" 'feat: a subject\n\nthe body explains the change in full'
assert_lacks "body_required' FAILED|checks_failed=" "$(run_recipe bodyreq)" \
  "checks: body_required passes when a body is present"

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
mock_curl "$tmp" "" "$sniff"
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

# A2. --recipe auto + non-diff context -> exit 2, clear "could not infer".
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(printf 'just some prose, not a diff at all' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto prose "go" 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe auto (non-diff): exit 2"
assert_contains "could not infer" "$out" "--recipe auto (non-diff): clear error"

# A3. --recipe auto with no piped context -> exit 2, "needs context".
tmp=$(mktemp -d)
mock_curl "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe auto prose "go" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe auto (no stdin): exit 2"
assert_contains "needs context" "$out" "--recipe auto (no stdin): clear error"

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
  mock_curl "$tmp" "" "$sniff"
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
  assert_not_contains "a.txt" "$payload" "--recipe auto (backfill): diff_stat does NOT leak the staged index file"
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
    assert_not_contains "$trailer" "$payload" "--recipe auto (backfill): $trailer is stripped from recent_commits (#501)"
  done
  rm -rf "$tmp" "$metrics"

  # A5. A clean tree with the diff piped from elsewhere still fills diff_stat.
  tmp=$(mktemp -d)
  sniff="$tmp/payload.json"
  mock_curl "$tmp" "" "$sniff"
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
mock_curl "$tmp" "" "$sniff"
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
assert_not_contains "no installed model matches this tier" "$out" "unknown tier: suppresses the misleading no-installed-model advice"
assert_contains '"exit_status":2' "$(cat "$metrics")" "unknown tier: metrics row tagged exit_status 2"

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

# --- #342: the caller can state the project the delegation is for, since the
# cwd derivation is wrong when delegate.sh runs from another checkout ---
tmp=$(mktemp -d)
mock_curl "$tmp"
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

# 34. The dispatch curl carries --max-time (default 600 s) and --connect-timeout.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
mock_curl "$tmp" "" /dev/null "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 600" "$argv" "ollama dispatch defaults to 600s"
assert_contains "--connect-timeout 5" "$argv" "ollama dispatch passes --connect-timeout"

# 35. DELEGATE_REQUEST_TIMEOUT overrides the default.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
mock_curl "$tmp" "" /dev/null "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_REQUEST_TIMEOUT=42 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 42" "$argv" "DELEGATE_REQUEST_TIMEOUT overrides the default"

# 36. The MLX dispatch curl gets the same bounds.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff" 2>/dev/null)
assert_contains "--max-time 600" "$argv" "mlx dispatch defaults to 600s"
assert_contains "--connect-timeout 5" "$argv" "mlx dispatch passes --connect-timeout"

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

# 41. An unknown host is labelled host:port so two stay distinguishable.
tmp=$(mktemp -d)
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$tmp/argv.txt"
metrics=$(mktemp)
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_BASE_URL="http://localhost:9999/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
assert_contains '"backend":"localhost:9999"' "$(cat "$metrics")" "unknown provider is labelled host:port"

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

# 46. `--tier NAME` (#411) wins over the positional tier and moves the prompt
# to the first positional; the historical `<tier> ["<prompt>"]` order is untouched.
tmp=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier prose "Summarise this" </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier sets the tier"
assert_contains "Summarise this" "$(cat "$tmp/payload.json")" "--tier moves the prompt to the first positional"

# `code` is unresolvable with this mock's single prose model, so a pass
# proves the flag won rather than agreeing with the positional.
tmp=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier prose code "Summarise" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "--tier overrides the positional tier"
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier overrides the positional tier in metrics"

# --tier=NAME is accepted too.
tmp=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --tier=prose "Summarise" </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "--tier=NAME sets the tier"

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

# An unrecognised flag in the tier slot is a usage error, diagnosed as a flag
# and refused before any row is written: the corpus once recorded
# tier:"--file" (#550).
for bad_args in '--file|Summarise' '--file|x|prose|Summarise'; do
  tmp=$(mktemp -d); metrics=$(mktemp)
  mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
  IFS='|' read -r -a bad_argv <<< "$bad_args"
  EC=0
  out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
    bash "$SCRIPT" "${bad_argv[@]}" </dev/null 2>&1) || EC=$?
  assert_eq 2 "$EC" "an unknown flag in the tier slot -> exit 2 ($bad_args)"
  assert_contains "is not a flag delegate.sh knows" "$out" "unknown flag is diagnosed as a flag, not a tier ($bad_args)"
  assert_contains "--tier NAME" "$out" "unknown flag names --tier as the alternative ($bad_args)"
  assert_eq 0 "$(wc -c < "$metrics" | tr -d ' ')" "unknown flag writes no metrics row ($bad_args)"
  rm -rf "$tmp" "$metrics"
done

# A dash-leading prompt works without `--`: it is the second positional and
# never reaches the option parser.
tmp=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "-not a flag" </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "a dash-leading prompt still works without --"
assert_contains "-not a flag" "$(cat "$tmp/payload.json")" "a dash-leading prompt reaches the model intact"

# The historical positional order is untouched.
tmp=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
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
  mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
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
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
mk_recipe "$pdir" "r_prose" "prose"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_prose "Match the example messages exactly in shape and tone." </dev/null >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "a lone sentence positional is the prompt, not the tier"
assert_contains '"tier":"prose"' "$(cat "$metrics")" "lone sentence positional keeps the declared tier"
assert_contains "Match the example messages" "$(cat "$tmp/payload.json")" "lone sentence positional reaches the model as the prompt"

# A lone positional that is a tier name is still the tier.
tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
mk_recipe "$pdir" "r_reason" "reasoning"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_reason prose </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"prose"' "$(cat "$metrics")" "a lone positional matching a tier name is still the tier"

# An explicit tier wins over the declared one.
tmp=$(mktemp -d); pdir=$(mktemp -d); metrics=$(mktemp)
mock_curl "$tmp" 'mlx-output-ok' "$tmp/payload.json"
mk_recipe "$pdir" "r_prose" "prose"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_PROMPTS_DIR="$pdir" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --recipe r_prose --tier code </dev/null >/dev/null 2>&1 || true
assert_contains '"tier":"code"' "$(cat "$metrics")" "--tier overrides the recipe's declared tier"

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


# --- 40. no_example_echo (ADR 0029): on by default for every recipe call,
# fails when the output reproduces a line of the recipe's own prompt ---
fresh
recipe_stdin="unrelated facts about a config loader"
mk_check_recipe anchor "" $'Answer using only the facts below.\n\nWrong: The regression is in the date parser, and ask the reporter to confirm it.\nCorrect: The regression is in the date parser. Could you confirm whether it also happens on older inputs?\n\n=== Facts ===\n{{stdin}}'
# 40a. Output that reproduces the Correct: example verbatim -> FAILED + named.
mock_curl "$tmp" 'The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
out=$(run_recipe anchor)
assert_contains "check 'no_example_echo' FAILED" "$out" "echo-check: verbatim example reproduction is caught"
assert_contains "REJECT this draft" "$out" "echo-check: stderr tells the caller not to ship it"
assert_contains '"checks_failed_names":["no_example_echo"]' "$(tail -1 "$metrics")" "echo-check: named on the metrics row"
# 40e. The comparison runs against the pre-substitution template, so
# reproducing a piped fact never flags.
recipe_stdin="The token drop is on the Teams side, inside its own MSAL cache layer."
mock_curl "$tmp" "$recipe_stdin"
assert_not_contains "no_example_echo" "$(run_recipe anchor)" "echo-check: reproducing piped context does not flag"

# --- 40h. echo_guard_vars (#428): a recipe declares which --var values are
# shape anchors, and their lines join the forbidden-output set ---
recipe_stdin=x
mk_check_recipe cm "" $'Write a commit message.\n\n=== Recent commits (SHAPE anchors) ===\n{{recent_commits}}\n\n=== Why ===\n{{why}}' \
  $'inputs:\n  recent_commits: string\n  why: string\necho_guard_vars: recent_commits'
ANCHORS='chore(deps): bump codeql-action init and analyze together to v4.37.6 (#253)
chore(deps): bump github/codeql-action/analyze from 4.37.3 to 4.37.4 (#240)
perf(football): cut CI validate from 34 to 7 minutes (#287)'
# 40h-i. Type prefix and PR suffix are stripped from both sides, so an
# anchor echoed under a different prefix is caught.
mock_curl "$tmp" 'ci: bump codeql-action init and analyze together to v4.37.6\n\nCombines the Dependabot PRs.'
out=$(run_recipe cm --var recent_commits="$ANCHORS" --var why="w")
assert_contains "check 'no_example_echo' FAILED" "$out" \
  "echo-guard: anchor subject echoed under a different type prefix is caught"
assert_contains '"checks_failed_names":["no_example_echo"]' "$(tail -1 "$metrics")" \
  "echo-guard: named on the metrics row"
# 40h-v. Without the declaration the vars are ordinary content: the guard is opt-in.
sed '/^echo_guard_vars:/d' "$prompts/cm.md" > "$prompts/cm2.md"
assert_not_contains "no_example_echo" "$(run_recipe cm2 --var recent_commits="$ANCHORS" --var why="w")" \
  "echo-guard: undeclared vars are not guarded (opt-in)"
unset recipe_stdin

# --- 41. Draft capture: the output is persisted beside its metrics row so a
# later MISS carries the artefact ---
fresh
data="$tmp/data"; mkdir -p "$data"
metrics="$data/metrics.jsonl"
mode_of() { perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$1"; }
mk_check_recipe cap "" $'GO\n{{stdin}}'
mock_curl "$tmp" 'a draft worth keeping around'
run_recipe cap >/dev/null
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
assert_true "draft-capture: draft_file names a file that exists" test -n "$draft_name" -a -f "$data/drafts/$draft_name"
assert_eq "a draft worth keeping around" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: file holds the generated output verbatim"
# The name leads with the row ts and carries a suffix, since ts alone is
# second-precision and parallel delegations share it.
row_ts=$(printf '%s' "$row" | jq -r '.ts')
assert_true "draft-capture: filename leads with the row ts and is suffixed" \
  test "${draft_name%%-*}" = "$(printf '%s' "$row_ts" | tr -d ':-')" -a "${draft_name%.draft.txt}" != "$draft_name"
# 41a-i. Two delegations in the same second must not clobber each other.
# Drafts only: a recipe call also stores its input beside each draft (#516).
before_count=$(ls "$data/drafts" | grep -c '\.draft\.txt$')
run_recipe cap >/dev/null
run_recipe cap >/dev/null
assert_eq "$((before_count + 2))" "$(ls "$data/drafts" | grep -c '\.draft\.txt$')" \
  "draft-capture: two same-second delegations write two distinct files"
missing=0
while IFS= read -r df; do
  [[ -z "$df" ]] && continue
  [[ -f "$data/drafts/$df" ]] || missing=$((missing+1))
done < <(jq -r '.draft_file // empty' "$metrics")
assert_eq 0 "$missing" "draft-capture: every draft_file on a row exists on disk"
# 41a-ii. Drafts hold piped context, so directory and files must not inherit
# a permissive umask; only a wide-open umask makes the bug visible.
rm -rf "$data"; mkdir -p "$data"
( umask 000; run_recipe cap >/dev/null )
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_eq "700" "$(mode_of "$data/drafts")" \
  "draft-capture: drafts directory is private (700) under a permissive umask"
assert_eq "600" "$(mode_of "$data/drafts/$draft_name")" \
  "draft-capture: draft file is private (600) under a permissive umask"
# 41b. Opt-out.
rm -rf "$data"; mkdir -p "$data"
run_recipe DELEGATE_NO_DRAFT_CAPTURE=1 cap >/dev/null
assert_eq "false" "$(tail -1 "$metrics" | jq -r 'has("draft_file")')" \
  "draft-capture: DELEGATE_NO_DRAFT_CAPTURE=1 writes no draft_file field"
assert_eq "false" "$(tail -1 "$metrics" | jq -r 'has("input_file")')" \
  "draft-capture: DELEGATE_NO_DRAFT_CAPTURE=1 writes no input_file field either"
assert_false "draft-capture: opt-out creates no drafts directory" test -d "$data/drafts"
# 41c. Metrics off means no row to join to, so no draft either.
rm -rf "$data"; mkdir -p "$data"
run_recipe DELEGATE_LOCAL_NO_METRICS=1 cap >/dev/null
assert_false "draft-capture: NO_METRICS captures no draft" test -d "$data/drafts"
# 41d. Oversized output is truncated with a marker rather than dropped.
rm -rf "$data"; mkdir -p "$data"
mock_curl "$tmp" 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
run_recipe DELEGATE_DRAFT_MAX_BYTES=20 cap >/dev/null
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_contains "[truncated at 20 bytes" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: oversized draft is truncated with a marker"
# 41e. The cap is in bytes: eight 3-byte characters are 24 bytes. LANG is
# set because under `env -i` (C locale) bash counts bytes anyway.
rm -rf "$data"; mkdir -p "$data"
mock_curl "$tmp" '中文测试中文测试'
run_recipe LANG=en_US.UTF-8 DELEGATE_DRAFT_MAX_BYTES=20 cap >/dev/null
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_contains "[truncated at 20 bytes" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: byte cap measured in bytes, not characters"
# 41f. A malformed cap falls back to the default.
rm -rf "$data"; mkdir -p "$data"
mock_curl "$tmp" 'short'
assert_contains "is not a positive integer" "$(run_recipe DELEGATE_DRAFT_MAX_BYTES=abc cap)" \
  "draft-capture: malformed byte cap is reported"
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_eq "short" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "draft-capture: malformed byte cap still captures under the default bound"
# 41g. The rendered input the model saw is stored beside the draft under the
# same stem and named on the row (#516), so the calibration loop can score the
# pair against the supplied facts without the caller re-supplying them.
rm -rf "$data"; mkdir -p "$data"
mk_check_recipe capin "" $'RENDERED-TEMPLATE-MARKER\nFacts:\n{{stdin}}'
mock_curl "$tmp" 'a draft worth keeping around'
recipe_stdin='the distinctive piped fact about widget-7'
( umask 000; run_recipe capin >/dev/null )
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
input_name=$(printf '%s' "$row" | jq -r '.input_file // ""')
assert_eq "${draft_name%.draft.txt}.input.txt" "$input_name" \
  "input-capture: input_file shares the draft's stem"
assert_true "input-capture: draft and input both exist on disk" \
  test -n "$input_name" -a -f "$data/drafts/$draft_name" -a -f "$data/drafts/$input_name"
input_body=$(cat "$data/drafts/$input_name" 2>/dev/null)
assert_contains "RENDERED-TEMPLATE-MARKER" "$input_body" "input-capture: file holds the recipe template"
assert_contains "the distinctive piped fact about widget-7" "$input_body" \
  "input-capture: file holds the piped context, substituted for {{stdin}}"
assert_eq $'RENDERED-TEMPLATE-MARKER\nFacts:\nthe distinctive piped fact about widget-7\n\ngo' "$input_body" \
  "input-capture: file is exactly the rendered prompt the model was sent"
assert_eq "600" "$(mode_of "$data/drafts/$input_name")" \
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
assert_true "input-capture: a bare call writes no input file" \
  test -n "$draft_name" -a ! -e "$data/drafts/${draft_name%.draft.txt}.input.txt"
# 41g-ii. Retention prunes the input with the draft it belongs to.
old_stem="20200101T000000Z-deadbeef"
printf 'old' > "$data/drafts/$old_stem.draft.txt"
printf 'old' > "$data/drafts/$old_stem.input.txt"
touch -t 202001010000 "$data/drafts/$old_stem.draft.txt" "$data/drafts/$old_stem.input.txt"
recipe_stdin=ctx
run_recipe DELEGATE_DRAFT_RETENTION_DAYS=1 capin >/dev/null
assert_eq 0 "$(ls "$data/drafts" | grep -c "^$old_stem")" \
  "input-capture: retention removes the expired draft and its input"
# 41h. The structured inputs — piped stdin, every --var as passed, the
# positional prompt — are stored as JSON under the same stem and named on the
# row as inputs_file, and the row carries the template's content hash, so
# replay-recipe.sh can render the same case under another template and the
# outcomes before and after an edit can be told apart.
rm -rf "$data"; mkdir -p "$data"
mk_check_recipe capvar "" $'To {{who}}:\n{{stdin}}\nNote: {{note}}' $'inputs:\n  stdin: string\n  who: string\n  note: string?'
mock_curl "$tmp" 'a draft'
recipe_stdin='fact one about widget-7'
run_recipe capvar --var who=alice --var "note=$(printf 'two\nlines')" >/dev/null
row=$(tail -1 "$metrics")
draft_name=$(printf '%s' "$row" | jq -r '.draft_file // ""')
inputs_name=$(printf '%s' "$row" | jq -r '.inputs_file // ""')
assert_eq "${draft_name%.draft.txt}.inputs.json" "$inputs_name" \
  "inputs-capture: inputs_file shares the draft's stem"
inputs_path="$data/drafts/$inputs_name"
assert_true "inputs-capture: the inputs file exists on disk" test -n "$inputs_name" -a -f "$inputs_path"
assert_eq "capvar" "$(jq -r '.recipe' "$inputs_path" 2>/dev/null)" "inputs-capture: file names the recipe"
assert_eq "fact one about widget-7" "$(jq -r '.stdin' "$inputs_path" 2>/dev/null)" \
  "inputs-capture: file holds the piped stdin"
assert_eq "alice" "$(jq -r '.vars.who' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds each --var by key"
assert_eq $'two\nlines' "$(jq -r '.vars.note' "$inputs_path" 2>/dev/null)" \
  "inputs-capture: a --var value keeps its newline"
assert_eq "go" "$(jq -r '.prompt' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds the positional prompt"
assert_eq "prose" "$(jq -r '.tier' "$inputs_path" 2>/dev/null)" "inputs-capture: file holds the resolved tier"
assert_eq "600" "$(mode_of "$inputs_path")" "inputs-capture: inputs file is private (600)"
# The hash covers the frontmatter and the prompt block, the parts that shape
# the output, and is computed by the helper both scripts share.
. "$REPO/scripts/lib/recipe.sh"
expected_sha=$(recipe_template_sha "$prompts/capvar.md")
assert_eq "$expected_sha" "$(printf '%s' "$row" | jq -r '.template_sha // ""')" \
  "template-sha: the row carries the 12-char hash of the recipe's frontmatter and prompt block"
assert_true "template-sha: the hash is 12 hex characters" grep -qE '^[0-9a-f]{12}$' <<< "$expected_sha"
# A key passed twice keeps its first value in the inputs, because that is
# the value the substitution used.
recipe_stdin=ctx
run_recipe capvar --var who=alice --var who=bob >/dev/null
row=$(tail -1 "$metrics")
dup_inputs="$data/drafts/$(printf '%s' "$row" | jq -r '.inputs_file // ""')"
dup_input="$data/drafts/$(printf '%s' "$row" | jq -r '.input_file // ""')"
assert_contains "To alice:" "$(cat "$dup_input" 2>/dev/null)" \
  "inputs-capture: a --var passed twice is rendered with its first value"
assert_eq "alice" "$(jq -r '.vars.who' "$dup_inputs" 2>/dev/null)" \
  "inputs-capture: a --var passed twice is recorded with its first value"
# A calibration note does not change the hash; an edit to the prompt block does.
printf '\n## Calibration notes\n- 2026-09-19: a dated note, prose only\n' >> "$prompts/capvar.md"
run_recipe capvar --var who=dora >/dev/null
assert_eq "$expected_sha" "$(tail -1 "$metrics" | jq -r '.template_sha // ""')" \
  "template-sha: a calibration-notes edit keeps the hash"
sed -i.bak 's/^To {{who}}:$/Dear {{who}}:/' "$prompts/capvar.md" && rm -f "$prompts/capvar.md.bak"
run_recipe capvar --var who=erin >/dev/null
edited_sha=$(tail -1 "$metrics" | jq -r '.template_sha // ""')
assert_true "template-sha: a prompt-block edit changes the hash" test -n "$edited_sha" -a "$edited_sha" != "$expected_sha"
# Over the byte cap the JSON is not written at all: a cut JSON is unreadable.
run_recipe DELEGATE_DRAFT_MAX_BYTES=40 capvar --var who=frank >/dev/null
row=$(tail -1 "$metrics")
assert_eq "true" "$(printf '%s' "$row" | jq -r 'has("draft_file")')" \
  "inputs-capture: over the cap the draft is still captured (truncated)"
assert_eq "false" "$(printf '%s' "$row" | jq -r 'has("inputs_file")')" \
  "inputs-capture: over the cap no inputs file is written and no field names one"
# The draft alone can be switched off and the hash still lands: it is on
# the row, not in a file.
run_recipe DELEGATE_NO_DRAFT_CAPTURE=1 capvar --var who=bob >/dev/null
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
printf 'old' > "$data/drafts/$old_stem.draft.txt"
printf '{}' > "$data/drafts/$old_stem.inputs.json"
touch -t 202001010000 "$data/drafts/$old_stem.draft.txt" "$data/drafts/$old_stem.inputs.json"
run_recipe DELEGATE_DRAFT_RETENTION_DAYS=1 capvar --var who=carol >/dev/null
assert_eq 0 "$(ls "$data/drafts" | grep -c "^$old_stem")" \
  "inputs-capture: retention removes the expired inputs file with its draft"
unset recipe_stdin
# mock_curl carries any content: an apostrophe, a double quote, a dollar
# sign, a backslash and a newline all reach the draft as the model sent them.
awkward=$'it\'s a "quoted" $HOME \\ path\nsecond line'
mock_curl "$tmp" "$(printf '%s' "$awkward" | jq -Rs . | sed 's/^"//; s/"$//')"
run_recipe cap >/dev/null
draft_name=$(tail -1 "$metrics" | jq -r '.draft_file // ""')
assert_eq "$awkward" "$(cat "$data/drafts/$draft_name" 2>/dev/null)" \
  "mock_curl: content with ' \" \$ \\ and a newline round-trips to the draft"

# --- 42-45. One wired case per check: the failure reaches stderr and the
# row. The rest of each check's cases are in tests/test-checks.sh ---
fresh
# 42a. body_max_words: over the limit fails and is named on the row.
mk_check_recipe bw 'body_max_words: 10'
mock_curl "$tmp" 'subject here\n\none two three four five six seven eight nine ten eleven twelve'
assert_contains "check 'body_max_words' FAILED — body is 12 words (> 10)" "$(run_recipe bw)" \
  "body_max_words: over-limit body fails with both counts named"
assert_contains '"checks_failed_names":["body_max_words"]' "$(tail -1 "$metrics")" \
  "body_max_words: named on the metrics row"
# 42f. The limit can come from the flavor profile.
mk_check_recipe bwf 'body_max_words: {{flavor_commit_body_max_words}}'
printf 'FLAVOR_COMMIT_BODY_MAX_WORDS=3\n' > "$tmp/profile.sh"
chmod 600 "$tmp/profile.sh"
mock_curl "$tmp" 'subject\n\none two three four five'
assert_contains "body is 5 words (> 3)" "$(run_recipe DELEGATE_LOCAL_PROFILE="$tmp/profile.sh" bwf)" \
  "body_max_words: the limit comes from the flavor profile"

# 43a. no_single_item_list: one sentence of verdict, then a single numbered ask.
mk_check_recipe sil 'no_single_item_list: true'
mock_curl "$tmp" '@swayamg20, the fix in sanitize_diagram() handles unquoted labels.\n1. Would you like to apply the two inline suggestions, or leave the pipe-label case for a follow-up?'
assert_contains "check 'no_single_item_list' FAILED" "$(run_recipe sil)" \
  "no_single_item_list: a one-item numbered list fails"
assert_contains '"checks_failed_names":["no_single_item_list"]' "$(tail -1 "$metrics")" \
  "no_single_item_list: named on the metrics row"

# 44a. no_invented_task_list fires only when the --var named in the
# frontmatter (the shape authority) has none: an unchecked `## Test plan`
# appended to a body the examples never showed one for.
mk_check_recipe tl 'no_invented_task_list: examples' 'Examples: {{examples}}'
mock_curl "$tmp" 'Suites: 366 passed, 94/94.\n\n## Test plan\n- [ ] Run the prompts suite (not run yet)\n- [ ] Run the unit suite (not run yet)'
out=$(run_recipe DELEGATE_NO_ECHO_CHECK=1 tl --var examples=$'TITLE: a merged PR\nBODY:\nTwo sentences of prose. No checklist.')
assert_contains "check 'no_invented_task_list' FAILED" "$out" \
  "no_invented_task_list: an invented task list fails"
assert_contains "carries 2 markdown task-list item(s)" "$out" \
  "no_invented_task_list: the count is named"
assert_contains '"checks_failed_names":["no_invented_task_list"]' "$(tail -1 "$metrics")" \
  "no_invented_task_list: named on the metrics row"

# --- 45. no_invented_refs: a trailer identifier must appear in the caller's
# --var values or piped context; the recipe template is excluded on purpose,
# because a Wrong example carrying a literal identifier gets copied (45d) ---
mk_check_recipe rf 'no_invented_refs: true' $'Examples: {{examples}}\nNever continue a numbering sequence. Wrong: Refs: ZZ-9915'
# 45a. The examples end in AI-812 / AI-806 and the model continues the sequence.
mock_curl "$tmp" 'A short body describing the change.\n\nRefs: AI-813'
out=$(run_recipe DELEGATE_NO_ECHO_CHECK=1 rf --var examples=$'TITLE: one\nBODY:\nprose\nRefs: AI-812\n\nTITLE: two\nBODY:\nprose\nRefs: AI-806')
assert_contains "check 'no_invented_refs' FAILED" "$out" \
  "no_invented_refs: an ungrounded trailer identifier fails"
assert_contains "trailer names AI-813" "$out" \
  "no_invented_refs: the invented identifier is named"
assert_contains '"checks_failed_names":["no_invented_refs"]' "$(tail -1 "$metrics")" \
  "no_invented_refs: named on the metrics row"
# 45d. An identifier that appears only in the recipe's own Wrong example is
# not grounded: the wrapper hands the check the vars and context, not the template.
mock_curl "$tmp" 'A short body.\n\nRefs: ZZ-9915'
assert_contains "trailer names ZZ-9915" "$(run_recipe DELEGATE_NO_ECHO_CHECK=1 rf --var examples=$'TITLE: one\nBODY:\nprose\nRefs: AI-812')" \
  "no_invented_refs: an identifier taken from the recipe's own text is not grounded"

# --- 47. Retry on check failure (#384): exactly one more generation naming
# the failed check, never a loop ---
fresh
mk_check_recipe rt 'subject_max: 12'

make_mock_curl_seq() {
  # Answers dispatches from a queue of canned contents, counting each in $2
  # (discovery is answered first and not counted) and saving the payload as
  # "$dir/payload.<n>.json". The last content repeats once the queue is
  # spent, so an unbounded retry shows as a count, not a hang. A queue entry
  # of __FAIL__ makes that dispatch exit 28 with no body (a transport
  # failure); __EMPTY__ answers with empty content.
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
if [[ "\$line" == "__FAIL__" ]]; then echo "curl: (28) Operation timed out" >&2; exit 28; fi
[[ "\$line" == "__EMPTY__" ]] && line=""
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
dispatches() { wc -l < "$counter" | tr -d ' '; }
# run_rt [off] — the rt recipe, DELEGATE_NO_RETRY=1 when given an argument.
run_rt() { run_recipe ${1:+DELEGATE_NO_RETRY=1} rt; }
long_subject='this subject line is far too long\n\nbody'

# 47a. A failed check re-generates once and the second output is delivered.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
run_rt >/dev/null
assert_eq 2 "$(dispatches)" "retry: a failed check costs exactly two dispatches"
assert_contains "short one" "$(cat "$tmp/stdout")" \
  "retry: the caller receives the retried output, not the rejected one"

# 47b. A first output that passes is never retried.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
run_rt >/dev/null
assert_eq 1 "$(dispatches)" "retry: a passing check costs exactly one dispatch"

# 47c. The retry names the failed check.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
run_rt >/dev/null
assert_contains "subject_max" "$(cat "$tmp/payload.2.json")" \
  "retry: the second request names the check that failed"
assert_not_contains "was rejected" "$(cat "$tmp/payload.1.json")" "retry: the first request carries no rejection notice"

# 47d. One retry, never a loop: every response fails.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject"
EC=0
run_rt >/dev/null || EC=$?
assert_eq 2 "$(dispatches)" "retry: a check that keeps failing still costs exactly two dispatches"
assert_eq 0 "$EC" "retry: a still-failing check stays warn-only (exit 0)"
assert_contains '"checks_failed_names":["subject_max"]' "$(tail -1 "$metrics")" \
  "retry: the post-retry check state is what the metrics row records"

# 47e. The row says whether a retry happened, so the cost is measurable.
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "retry: a retried call is marked on the metrics row"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
run_rt >/dev/null
assert_not_contains '"retried"' "$(tail -1 "$metrics")" "retry: a call that was not retried carries no retried field"

# 47e-f. A retry that fails to dispatch keeps the first draft (#550): the
# caller gets the rejected-but-usable generation, told why, and the row
# describes that draft, not an empty failure.
for rt_fail in __FAIL__ __EMPTY__; do
  : > "$metrics"
  make_mock_curl_seq "$tmp" "$counter" "$long_subject" "$rt_fail"
  EC=0
  run_rt > "$tmp/rt.err" || EC=$?
  out=$(cat "$tmp/stdout")
  assert_eq 2 "$(dispatches)" "retry-failed ($rt_fail): the retry was attempted"
  assert_eq 0 "$EC" "retry-failed ($rt_fail): exits 0 with the first draft"
  assert_contains "this subject line is far too long" "$out" \
    "retry-failed ($rt_fail): the first draft is printed on stdout"
  assert_contains "first draft is returned" "$(cat "$tmp/rt.err")" \
    "retry-failed ($rt_fail): stderr says the retry failed and the first draft is returned"
  assert_contains "check 'subject_max' FAILED" "$(cat "$tmp/rt.err")" \
    "retry-failed ($rt_fail): the first draft's check failure is reported"
  row=$(tail -1 "$metrics")
  assert_eq "true|true|0|subject_max" \
    "$(printf '%s' "$row" | jq -r '[.retry_failed, .retried, .exit_status, (.checks_failed_names|join(","))] | map(tostring) | join("|")')" \
    "retry-failed ($rt_fail): row carries retry_failed, status 0 and the first draft's checks"
  assert_eq "${#out}" "$(printf '%s' "$row" | jq -r '.output_chars')" \
    "retry-failed ($rt_fail): output_chars measures the draft returned"
  assert_eq "$(printf '%s' "$row" | jq -r '((.prompt_chars + .context_chars + .output_chars + .retry_chars) / 4 | floor)')" \
    "$(printf '%s' "$row" | jq -r '.estimated_tokens_avoided')" \
    "retry-failed ($rt_fail): the row still reproduces its own token count"
  rt_input="$(dirname "$metrics")/drafts/$(printf '%s' "$row" | jq -r '.input_file')"
  assert_not_contains "REJECTED" "$(cat "$rt_input" 2>/dev/null || echo REJECTED-missing)" \
    "retry-failed ($rt_fail): the stored input is the prompt that produced the returned draft"
done
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
run_rt >/dev/null
assert_not_contains '"retry_failed"' "$(tail -1 "$metrics")" "retry: a retry that dispatched carries no retry_failed field"

# 47e-i. The rejected generation and the notice ride retry_chars rather than
# inflating prompt_chars / output_chars, and the row still reproduces its
# own token count.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
run_rt >/dev/null
row=$(tail -1 "$metrics")
assert_true "retry: the rejected generation and the notice are counted" \
  test "$(printf '%s' "$row" | jq -r '.retry_chars // 0')" -gt 0
assert_eq "$(printf '%s' "$row" | jq -r '((.prompt_chars + .context_chars + .output_chars + .retry_chars) / 4 | floor)')" \
  "$(printf '%s' "$row" | jq -r '.estimated_tokens_avoided')" \
  "retry: the row still reproduces its own token count"

# 46-ii. A delegation from outside any git repository writes no project
# field rather than the scratch directory's name.
: > "$metrics"
outside="$tmp/not-a-repo"; mkdir -p "$outside"
mock_curl "$tmp"
( cd "$outside" && env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" prose "go" </dev/null >/dev/null 2>&1 )
assert_eq "false" "$(tail -1 "$metrics" | jq -r 'has("project")')" \
  "project: a delegation outside a repo writes no project field"
( cd "$outside" && env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
    DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" --project delegate-local prose "go" </dev/null >/dev/null 2>&1 )
assert_eq "delegate-local" "$(tail -1 "$metrics" | jq -r '.project')" \
  "project: --project still names it from outside a repo"

# 47e-i-b. The rejected generation is measured before the checks run, since
# the auto-strip mutates $output in place. Differential, because a retried
# row reports only the post-retry check state: two first outputs that differ
# by a trailing padding clause must differ in retry_chars by that clause.
mk_check_recipe rp $'subject_max: 12\nno_padding_tail: true'
plain_body='this subject line is far too long\n\nthe body says a thing'
padded_body="${plain_body}, ensuring the change is covered"
# Precondition: the padded tail is one the auto-strip takes.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$padded_body"
run_recipe DELEGATE_NO_RETRY=1 rp >/dev/null
assert_eq 1 "$(tail -1 "$metrics" | jq -r '.checks_autofixed')" \
  "retry: the padded tail used below is one the auto-strip takes"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$plain_body" 'short one\n\nbody'
run_recipe rp >/dev/null
rc_plain=$(tail -1 "$metrics" | jq -r '.retry_chars')
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$padded_body" 'short one\n\nbody'
run_recipe rp >/dev/null
assert_true "retry: the rejected generation is measured before the auto-strip" \
  test "$(tail -1 "$metrics" | jq -r '.retry_chars')" -gt "$rc_plain"

# 47e-ii. duration_ms covers both dispatches, so queue_wait_ms carries both
# waits; the mock reports 1 ms per dispatch.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
run_rt >/dev/null
assert_eq 2 "$(tail -1 "$metrics" | jq -r '.queue_wait_ms')" \
  "retry: queue_wait_ms carries both dispatches' waits"
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" 'short one\n\nbody'
run_rt >/dev/null
assert_eq 1 "$(tail -1 "$metrics" | jq -r '.queue_wait_ms')" \
  "retry: a single dispatch still reads one wait"

# 47e-iii. The OTel span carries the same retry_chars as the row.
: > "$metrics"
otel_body="$tmp/otel.json"
make_mock_curl_seq "$tmp" "$counter" "$long_subject" 'short one\n\nbody'
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
run_recipe DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" rt >/dev/null
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
make_mock_curl_seq "$tmp" "$counter" "$long_subject"
out=$(run_rt off)
assert_eq 1 "$(dispatches)" "retry: DELEGATE_NO_RETRY=1 dispatches once even on a failure"
assert_contains "check 'subject_max' FAILED" "$out" \
  "retry: DELEGATE_NO_RETRY=1 still reports the failure"

# 47g. A bare call declares no checks, so it is never retried.
: > "$metrics"
make_mock_curl_seq "$tmp" "$counter" "$long_subject"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_NO_PREFLIGHT=1 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "go" </dev/null >/dev/null 2>&1
assert_eq 1 "$(dispatches)" "retry: a bare call is never retried"

# --- no_invented_headings: same contract as no_invented_task_list, for
# markdown headings. Headings with bullets under them, against heading-free
# exemplars ---
mk_check_recipe hd 'no_invented_headings: examples' 'Examples: {{examples}}'
mock_curl "$tmp" 'A paragraph of prose.\n\n### Implementation Details\n- Capture: pre-post.\n\n### Testing\n- 18 new assertions.'
out=$(run_recipe DELEGATE_NO_ECHO_CHECK=1 DELEGATE_NO_RETRY=1 hd --var examples=$'TITLE: a merged PR\nBODY:\nTwo sentences of prose. No headings at all.')
assert_contains "check 'no_invented_headings' FAILED" "$out" \
  "no_invented_headings: an invented heading fails"
assert_contains "carries 2 markdown heading(s)" "$out" \
  "no_invented_headings: the count is named"
assert_contains '"checks_failed_names":["no_invented_headings"]' "$(tail -1 "$metrics")" \
  "no_invented_headings: named on the metrics row"

# --- 48. no_context_echo (#475): opt-in per recipe, fails when two or more
# distinct piped sentences come back verbatim; one is legitimate anchor-carrying ---
fresh
counter="$tmp/calls"
mk_check_recipe ce 'no_context_echo: true' $'Reply using only the facts below.\n\n=== VERDICT ===\n{{verdict}}\n\n=== FACTS ===\n{{stdin}}'
ce_facts=$'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe regression predates the refactor by two releases.'
ce_verdict='The rework is right and the blank window is not a regression from it at all.'
recipe_stdin="$ce_facts"
# run_ce [RECIPE] [ENV=VALUE...] — $ce_facts piped, $ce_verdict as the --var, no retry.
run_ce() { local r="${1:-ce}"; shift 2>/dev/null; run_recipe DELEGATE_NO_RETRY=1 "$@" "$r" --var verdict="$ce_verdict"; }
two_facts='The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.'

# 48a. Two supplied lines handed straight back -> FAILED, named, counted.
: > "$metrics"
mock_curl "$tmp" "Not a regression.\\n${two_facts}\\nCould you add a test?"
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

# 48a-iii. A --var value is not a pattern: the verdict plus one fact is one
# echoed sentence, not two.
: > "$metrics"
mock_curl "$tmp" "${ce_verdict} The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412. Could you add a test?"
assert_not_contains "no_context_echo" "$(run_ce)" "context-echo: a reproduced --var value does not count as an echo"
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "context-echo: the --var case still ran the check"

# 48b. Anchors carried inside new sentences never flag.
mock_curl "$tmp" 'Not a regression.\nThe flip is in the Electron 39 upgrade, specifically the sandbox flag at src/main.js:412, two releases before the refactor.\nI re-ran the suite with the flag forced back on and all 531 tests pass, so PR #2632 is not the cause.\nCould you add a test?'
: > "$metrics"
assert_not_contains "no_context_echo" "$(run_ce)" "context-echo: anchors carried in new sentences do not flag"
# Silence must mean "ran and passed", not "never ran".
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "context-echo: the silent case still ran the check"

# 48f. Opt-in: an undeclared recipe never runs it.
mk_check_recipe ce_off "" $'Reply using only the facts below.\n\n=== FACTS ===\n{{stdin}}'
: > "$metrics"
mock_curl "$tmp" "$two_facts"
assert_not_contains "no_context_echo" "$(run_ce ce_off)" "context-echo: an undeclared check does not run"
assert_contains '"checks_run":1' "$(tail -1 "$metrics")" \
  "context-echo: undeclared, only the default echo check is counted"

# 48f-ii. DELEGATE_NO_ECHO_CHECK=1 silences both echo checks.
: > "$metrics"
assert_not_contains "no_context_echo" "$(run_ce ce DELEGATE_NO_ECHO_CHECK=1)" "context-echo: DELEGATE_NO_ECHO_CHECK=1 silences it too"
assert_not_contains '"checks_run"' "$(tail -1 "$metrics")" "context-echo: an opted-out call counts neither echo check"

# 48g. Echo alone is NOT retried (#514): the second generation came back the
# same size and the same echo on 8 of the 12 maintainer-review-reply retries
# measured over 2026-09-13/14, so the notice does not repair it and the
# retry is a wasted generation. The check still fails, prints its reject and
# is named on the row; the row carries no retried / retry_chars.
make_mock_curl_seq "$tmp" "$counter" "$two_facts" \
  'The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on, so PR #2632 is clear.'
: > "$metrics"
err=$(run_recipe ce --var verdict="$ce_verdict")
assert_eq 1 "$(dispatches)" "context-echo: echo alone costs exactly one dispatch (no retry, #514)"
assert_contains "All 531 tests pass on the branch" "$(cat "$tmp/stdout")" \
  "context-echo: the caller receives the flagged first generation"
assert_contains "check 'no_context_echo' FAILED" "$err" \
  "context-echo: the reject is still printed when no retry follows"
assert_not_contains "regenerating once" "$err" "context-echo: echo alone announces no regeneration"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_context_echo"]' "$row" \
  "context-echo: the skipped retry still names the failure on the row"
assert_lacks '"retried"|"retry_chars"' "$row" "context-echo: echo alone leaves retried and retry_chars off the row"

# 48h. Echo beside another failed check still takes the retry: the gate is
# "only echo failed", not "echo failed". max_context_ratio is the realistic
# partner (both reply recipes declare the pair), so the context has to clear
# the ratio floor.
mk_check_recipe cer $'no_context_echo: true\nmax_context_ratio: 0.8' $'Reply using only the facts below.\n\n=== FACTS ===\n{{stdin}}'
cer_facts=""
for i in 1 2 3 4 5 6; do
  cer_facts="${cer_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 now.
"
done
make_mock_curl_seq "$tmp" "$counter" \
  "$(printf '%s' "$cer_facts" | tr '\n' ' ')" \
  'The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.'
: > "$metrics"
recipe_stdin="$cer_facts"
run_recipe cer >/dev/null
assert_eq 2 "$(dispatches)" "context-echo: echo beside max_context_ratio still costs two dispatches"
assert_contains "so the branch is clear" "$(cat "$tmp/stdout")" \
  "context-echo: the caller receives the retried output when another check drove the retry"
assert_contains "max_context_ratio: the answer runs about as long as the supplied facts" "$(cat "$tmp/payload.2.json")" \
  "context-echo: the second request names the check that drove the retry"
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "context-echo: a retry driven by another check is marked on the row"
assert_not_contains '"checks_failed_names"' "$(tail -1 "$metrics")" "context-echo: a clean retry leaves no failed check on the row"

# --- 49. max_context_ratio (#487): fails when output_chars / context_chars
# >= the declared ratio and the context is at least min_context_chars
# (default 400); opt-in, warn-only, retried with its own constraint ---
fresh
counter="$tmp/calls"
mcr_tpl=$'Reply using only the facts below.\n\n=== FACTS ===\n{{stdin}}'
mk_check_recipe mcr 'max_context_ratio: 0.8' "$mcr_tpl"
mk_check_recipe mcr_none 'no_padding_tail: true' "$mcr_tpl"
# Eight facts of ~90 chars: well over the 400-char default floor.
mcr_facts=""
for i in 1 2 3 4 5 6 7 8; do
  mcr_facts="${mcr_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 now.
"
done
recipe_stdin="$mcr_facts"
# A long answer (~7 sentences of ~100 chars, ratio near 1.0) and a short one.
mcr_short='The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.'
mcr_long="$(for i in 1 2 3 4 5 6; do printf '%s ' "${mcr_short% clear.} clear now."; done)$mcr_short"

# 49a. Long answer against a long context -> FAILED, named, counted.
: > "$metrics"
mock_curl "$tmp" "$mcr_long"
out=$(run_recipe DELEGATE_NO_RETRY=1 mcr)
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
mock_curl "$tmp" "$mcr_short"
assert_not_contains "max_context_ratio" "$(run_recipe DELEGATE_NO_RETRY=1 mcr)" "context-ratio: an answer well under the ratio passes"
row=$(tail -1 "$metrics")
assert_contains '"checks_run":2' "$row" \
  "context-ratio: a passing check is still counted as run"
assert_not_contains '"checks_failed_names"' "$row" "context-ratio: a passing check leaves no failed name on the row"

# 49d. Undeclared recipes never run it, however long the answer.
: > "$metrics"
mock_curl "$tmp" "$mcr_long"
assert_not_contains "max_context_ratio" "$(run_recipe DELEGATE_NO_RETRY=1 mcr_none)" "context-ratio: an undeclared recipe never runs it"
assert_not_contains 'max_context_ratio' "$(tail -1 "$metrics")" "context-ratio: an undeclared recipe leaves it off the row"

# 49e. The retry carries its own constraint sentence and a clean second
# generation clears the row.
make_mock_curl_seq "$tmp" "$counter" "$mcr_long" "$mcr_short"
: > "$metrics"
run_recipe mcr >/dev/null
assert_eq 2 "$(dispatches)" \
  "context-ratio: a failed check costs exactly two dispatches"
assert_contains "max_context_ratio: the answer runs about as long as the supplied facts; curate it to well under the facts' length, in sentences of your own." "$(cat "$tmp/payload.2.json")" \
  "context-ratio: the second request carries the length constraint sentence"
assert_not_contains "no_context_echo:" "$(cat "$tmp/payload.2.json")" "context-ratio: the retry names only the check that failed"
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "context-ratio: the retry is marked on the metrics row"
assert_not_contains '"checks_failed_names"' "$(tail -1 "$metrics")" "context-ratio: a clean retry leaves no failed check on the row"
unset recipe_stdin

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
assert_true "review-reply floor: maintainer-review-reply.md declares min_context_chars: 900" \
  grep -qE '^[[:space:]]+min_context_chars:[[:space:]]*900[[:space:]]*$' <<< "$mrr_fm"
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
mock_curl "$tmp" "$(printf '%s' "$mrr_reply" | head -c 789)"
out=$(run_mrr 832)
assert_not_contains "max_context_ratio" "$out" "review-reply floor: a 789-char reply on 832 chars of facts passes"
assert_not_contains '"checks_failed_names"' "$(tail -1 "$metrics")" "review-reply floor: the 832-char case leaves no failed check on the row"
: > "$metrics"
mock_curl "$tmp" "$(printf '%s' "$mrr_reply" | head -c 813)"
out=$(run_mrr 693)
assert_not_contains "max_context_ratio" "$out" "review-reply floor: an 813-char reply on 693 chars of facts passes"
# 50b. The floor is exactly 900: 899 chars of facts are exempt, 900 are not.
mock_curl "$tmp" "$mrr_reply"
: > "$metrics"
out=$(run_mrr 899)
assert_not_contains "max_context_ratio" "$out" "review-reply floor: 899 chars of facts are exempt"
: > "$metrics"
out=$(run_mrr 900)
assert_contains "check 'max_context_ratio' FAILED" "$out" \
  "review-reply floor: 900 chars of facts are checked and a 0.97 ratio fails"
assert_contains 'max_context_ratio' "$(tail -1 "$metrics")" \
  "review-reply floor: the 900-char failure is named on the row"

# --- 51. no_fact_as_question (#513): opt-in per recipe, the value names the
# --var holding the asks; fails when a question's anchors are all in the
# piped facts and none in that var (or, with no anchor, two-plus content
# words from the facts and none from the var). Never retried on its own. ---
fresh
counter="$tmp/calls"
fq_tpl=$'Reply using only the facts below.\n\n=== OPENER ===\n{{opener}}\n\n=== ASK ===\n{{ask}}\n\n=== FACTS ===\n{{stdin}}'
mk_check_recipe fq 'no_fact_as_question: ask' "$fq_tpl"
mk_check_recipe fq_list $'no_single_item_list: true\nno_fact_as_question: ask' "$fq_tpl"
mk_check_recipe fq_echo $'no_context_echo: true\nno_fact_as_question: ask' "$fq_tpl"
mk_check_recipe fq_off 'no_padding_tail: true' "$fq_tpl"
recipe_stdin=$'The blank window is the GPU sandbox flag flip in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe token drop is on the Teams side, in its MSAL cache, not in teams-for-linux.'
fq_ask='whether the token survives a cold start of the app'
# run_fq RECIPE [ENV=VALUE...] — the facts piped, $fq_ask and an opener as vars.
run_fq() { local r="$1"; shift; run_recipe "$@" "$r" --var ask="$fq_ask" --var opener="Thanks for the report on build 4711."; }
fact_q='Not a regression, the flip is the sandbox flag at src/main.js:412. Could you confirm that all 531 tests pass on PR #2632?'

# 51a. A fact with anchors handed back as a question -> FAILED, quoted, named, counted.
: > "$metrics"
mock_curl "$tmp" "$fact_q"
out=$(run_fq fq DELEGATE_NO_RETRY=1)
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: a fact's anchors asked back to the reader are caught"
assert_contains 'Could you confirm that all 531 tests pass on PR #2632?' "$out" \
  "fact-question: the offending question is quoted"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_fact_as_question"]' "$row" \
  "fact-question: named on the metrics row"
assert_contains '"checks_run":2' "$row" \
  "fact-question: counted in checks_run beside the default echo check"

# 51b. The caller's ask as a question is the recipe's shape: never flagged,
# still counted as run.
: > "$metrics"
mock_curl "$tmp" 'The flip is the sandbox flag at src/main.js:412 in the Electron 39 upgrade. Could you check whether the token survives a cold start of the app?'
assert_not_contains "no_fact_as_question" "$(run_fq fq DELEGATE_NO_RETRY=1)" "fact-question: the caller's ask phrased as a question passes"
row=$(tail -1 "$metrics")
assert_contains '"checks_run":2' "$row" \
  "fact-question: the silent case still ran the check"
assert_not_contains '"checks_failed_names"' "$row" "fact-question: a passing check leaves no failed name on the row"

# 51d. Never retried on its own: one dispatch, the failure stays on the row
# and its stderr reaches the caller.
answer_q='The flip is the sandbox flag at src/main.js:412 and all 531 tests pass with it forced on. Could you check whether the token survives a cold start of the app?'
make_mock_curl_seq "$tmp" "$counter" "$fact_q" "$answer_q"
: > "$metrics"
out=$(run_recipe fq --var ask="$fq_ask" --var opener="Thanks.")
assert_eq 1 "$(dispatches)" "fact-question: a failure on its own costs exactly one dispatch"
assert_contains "check 'no_fact_as_question' FAILED" "$out" \
  "fact-question: the un-retried failure is reported to the caller"
row=$(tail -1 "$metrics")
assert_contains '"checks_failed_names":["no_fact_as_question"]' "$row" \
  "fact-question: the un-retried failure is on the row"
assert_not_contains '"retried"' "$row" "fact-question: the row is not marked retried"

# 51d-ii. Beside a check that does retry, the retry runs for that check and
# its notice names only that check.
make_mock_curl_seq "$tmp" "$counter" \
  'The flip is the sandbox flag at src/main.js:412.\n1. Could you confirm that all 531 tests pass on PR #2632?' "$answer_q"
: > "$metrics"
out=$(run_recipe fq_list --var ask="$fq_ask" --var opener="Thanks.")
assert_eq 2 "$(dispatches)" "fact-question: a retried check beside it still costs two dispatches"
assert_contains "check(s) no_single_item_list failed" "$out" \
  "fact-question: the retry line names only the check that earns it"
assert_not_contains "no_fact_as_question" "$(cat "$tmp/payload.2.json")" "fact-question: the retry notice leaves this check out"
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "fact-question: the other check's retry is marked on the row"

# 51d-iii. Beside no_context_echo, which does not earn the retry on its own
# either (#514), nothing is regenerated and both are named on the row.
make_mock_curl_seq "$tmp" "$counter" \
  'The blank window is the GPU sandbox flag flip in the Electron 39 upgrade at src/main.js:412. All 531 tests pass on the branch with the flag forced back on, see PR #2632. Could you confirm that all 531 tests pass on PR #2632?' \
  "$answer_q"
: > "$metrics"
run_recipe fq_echo --var ask="$fq_ask" --var opener="Thanks." >/dev/null
assert_eq 1 "$(dispatches)" "fact-question: beside echo alone, neither earns the retry: one dispatch"
assert_contains '"checks_failed_names":["no_context_echo","no_fact_as_question"]' "$(tail -1 "$metrics")" \
  "fact-question: beside echo alone, both failures are named on the row"

# 51e. Undeclared recipes never run it.
: > "$metrics"
mock_curl "$tmp" "$fact_q"
assert_not_contains "no_fact_as_question" "$(run_fq fq_off DELEGATE_NO_RETRY=1)" "fact-question: an undeclared recipe never runs it"
assert_contains '"checks_run":2' "$(tail -1 "$metrics")" \
  "fact-question: undeclared, only the declared and default checks are counted"
unset recipe_stdin

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
assert_false "lead: the refusal writes no metrics row" test -s "$metrics"
# 52b. With it, the stored input holds the lead verbatim, after the opener
# and before the piped facts, so the model was shown it in that position.
mock_curl "$tmp" 'Your trace was right, and this one is not ours to fix. The drop is in the MSAL cache on the Teams side. Could you check whether the token survives a cold start?'
printf '%s\n' "$mr_facts" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$REPO/prompts" \
  bash "$SCRIPT" --recipe maintainer-reply --var lead="$mr_lead" --var ask="whether the token survives a cold start" \
    --var opener="$mr_opener" prose "go" >/dev/null 2>&1
row=$(tail -1 "$metrics")
input_name=$(printf '%s' "$row" | jq -r '.input_file // ""')
assert_true "lead: the recipe call stores its rendered input" test -n "$input_name" -a -f "$data/drafts/$input_name"
input_body=$(cat "$data/drafts/$input_name" 2>/dev/null)
assert_contains "$mr_lead" "$input_body" "lead: the stored input carries the lead text verbatim"
lead_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_lead" | head -1 | cut -d: -f1)
opener_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_opener" | head -1 | cut -d: -f1)
facts_pos=$(printf '%s' "$input_body" | grep -n -F "$mr_facts" | head -1 | cut -d: -f1)
assert_true "lead: the stored input places the lead after the opener and before the facts" \
  test "${opener_pos:-0}" -gt 0 -a "${opener_pos:-0}" -lt "${lead_pos:-0}" -a "${lead_pos:-0}" -lt "${facts_pos:-0}"
assert_eq 1 "$(printf '%s' "$input_body" | grep -c -F "$mr_lead")" \
  "lead: the lead appears exactly once in the stored input"

# --- 53. no_unbidden_mention: opt-in per recipe, the value names the --var
# holding the recipient handle; fails on any @-mention that is not that
# handle, and on every mention when no handle was supplied. Measured
# 2026-09-22 over the stored corpus: 42 of 82 rejected reply drafts carry
# one, 0 of 81 shipped replies do. ---
fresh
mk_check_recipe um 'no_unbidden_mention: recipient' $'Reply using only the facts below.\n\n=== RECIPIENT ===\n{{recipient}}\n\n=== FACTS ===\n{{stdin}}' \
  $'inputs:\n  stdin: string\n  recipient: string?'
recipe_stdin=$'The crash is in src/main.js:412 and tomgunning reported it on the referenced issue.\nAll 531 tests pass on the branch.'

# 53a. No recipient supplied: any mention is unbidden, even when the name is
# in the piped facts (which is how both measured cases arose).
: > "$metrics"
mock_curl "$tmp" '@tomgunning, thanks for the report. The crash is at src/main.js:412 and all 531 tests pass.'
out=$(run_recipe DELEGATE_NO_RETRY=1 um)
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

# 53e. Undeclared is off: a recipe that does not name the var never runs it.
mk_check_recipe um_off 'no_padding_tail: true' $'Reply.\n\n{{stdin}}'
mock_curl "$tmp" '@tomgunning, thanks for the report.'
assert_not_contains "no_unbidden_mention" "$(run_recipe DELEGATE_NO_RETRY=1 um_off)" \
  "unbidden-mention: a recipe that does not declare it never runs it"

# 53f. The retry carries the constraint, so the second generation is told
# what to remove rather than being asked again.
: > "$metrics"
assert_contains "regenerating once" "$(run_recipe um)" \
  "unbidden-mention: a failed mention check earns the one retry"
assert_contains '"retried":true' "$(tail -1 "$metrics")" \
  "unbidden-mention: the retry is recorded on the row"
unset recipe_stdin

# --- 54. input_quality (#590): a recipe declares in its frontmatter which
# input gets which weak-shape detector; a weak input is named on ONE stderr
# warning line and recorded on the row as an `input_quality` array, and the
# call goes ahead, because an exit-2 refusal writes no row and teaches callers
# to pad or to skip delegating. Run against the REAL recipes so the
# declarations are proved through the wrapper. ---
tmp=$(mktemp -d)
data="$tmp/data"; mkdir -p "$data"
metrics="$data/metrics.jsonl"
mock_curl "$tmp" 'fix: keep the cache warm\n\nThe cache was cold on every start, so the first call paid the load.'
iq_fuller='commit 1c7b48a0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6
Author:     A <a@example.com>
AuthorDate: Mon Sep 28 10:00:00 2026 +0100
Commit:     A <a@example.com>
CommitDate: Mon Sep 28 10:00:00 2026 +0100

    fix: Loki sync survives bad rows

    One malformed row used to stop the whole sync; it is now skipped and counted.'
iq_diff='diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1 +1 @@
-a
+b'
iq_run() { # stdin-text, then delegate.sh args; stderr to $iq_err, row to $iq_row
  local stdin_text="$1"; shift
  : > "$metrics"
  iq_err=$(printf '%s' "$stdin_text" | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_LOCAL_DATA_DIR="$data" DELEGATE_NO_PREFLIGHT=1 DELEGATE_NO_RETRY=1 \
    DELEGATE_METRICS_FILE="$metrics" DELEGATE_PROMPTS_DIR="$REPO/prompts" \
    bash "$SCRIPT" "$@" 2>&1 >/dev/null)
  iq_rc=$?
  iq_row=$(tail -1 "$metrics" 2>/dev/null)
}
iq_field() { printf '%s' "$iq_row" | jq -c '.input_quality // "absent"'; }
iq_warn_lines() { printf '%s\n' "$iq_err" | grep -c 'weak input'; }

# 54a. commit-message with one subject line as its exemplar and no diff: both
# labels on the row, both named on one warning line, the call still ships.
iq_run "" --recipe commit-message --var recent_commits="fix: typo in README" \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq 0 "$iq_rc" "input-quality: a weak commit-message input is never refused"
assert_eq '["one_line_exemplar","no_diff"]' "$(iq_field)" \
  "input-quality: one-line exemplar and no diff both land on the row"
assert_eq 1 "$(iq_warn_lines)" "input-quality: the weak inputs share ONE warning line"
assert_contains "recent_commits=one_line_exemplar" "$iq_err" \
  "input-quality: the warning names recent_commits and its shape"
assert_contains "stdin=no_diff" "$iq_err" "input-quality: the warning names the missing diff"

# 54b. A --oneline list is one line per exemplar: no exemplar carries a body.
iq_run "$iq_diff" --recipe commit-message \
  --var recent_commits=$'8b9065f0 chore: update roadmap (#403)\n60e03baa chore(deps): bump the group (#404)\nbc012022 feat: lockfile tool (#400)' \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '["one_line_exemplar"]' "$(iq_field)" \
  "input-quality: a --oneline list is flagged as one-line exemplars"

# 54c. The gather step's own output (--pretty=fuller) with a diff piped is the
# legitimate input: no field, no warning.
iq_run "$iq_diff" --recipe commit-message --var recent_commits="$iq_fuller" \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '"absent"' "$(iq_field)" "input-quality: fuller exemplars and a diff leave no field"
assert_eq 0 "$(iq_warn_lines)" "input-quality: fuller exemplars and a diff print no warning"

# 54d. A diff stat piped where the diff belongs is still no diff.
iq_run " x.sh | 2 +-" --recipe commit-message --var recent_commits="$iq_fuller" \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '["no_diff"]' "$(iq_field)" "input-quality: a piped diff stat is flagged no_diff"

# 54e. pr-description given merged-PR titles only.
iq_run "" --recipe pr-description \
  --var recent_prs=$'#400 feat(audio): scenes that loop\n#399 Arcade music round 2' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq 0 "$iq_rc" "input-quality: a titles-only pr-description input is never refused"
assert_eq '["titles_only"]' "$(iq_field)" "input-quality: titles-only recent_prs lands on the row"
assert_contains "recent_prs=titles_only" "$iq_err" "input-quality: the warning names recent_prs"

# 54f. The gather step's envelope with a one-paragraph body and --limit 1 has
# no blank line at all once $(...) trims the trailing newline; its BODY: line
# is what marks it as carrying a body, so it is not flagged.
iq_run "" --recipe pr-description \
  --var recent_prs=$'<<<EXAMPLE_BEGIN PR #545>>>\nTITLE: fix: keep the first draft\nBODY:\nKeeps the first draft when the retry fails. Closes #550.\n<<<EXAMPLE_END>>>' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq '"absent"' "$(iq_field)" "input-quality: a gathered example with a body is not titles-only"
assert_eq 0 "$(iq_warn_lines)" "input-quality: a gathered example prints no warning"

# 54g. A body pasted without the envelope still has its paragraph break.
iq_run "" --recipe pr-description \
  --var recent_prs=$'fix: keep the first draft\n\nKeeps the first draft when the retry fails.' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq '"absent"' "$(iq_field)" "input-quality: a pasted title and body are not titles-only"

# 54h. A recipe that declares nothing never carries the field.
iq_run "one fact about the bug" --recipe summarise-issue --var kind=issue --var N_FACTS=3 prose "go"
assert_eq '"absent"' "$(iq_field)" "input-quality: an undeclaring recipe carries no field"

# 54h2. A subject-only --pretty=fuller entry has a blank line between its
# headers and its subject, which is not a body: flagged.
iq_fuller_subject_only='commit 59c7966b358a8ac01fac54f9b1ad15cb4203a956
Author:     A <a@example.com>
AuthorDate: Mon Sep 28 07:15:19 2026 +0100
Commit:     A <a@example.com>
CommitDate: Mon Sep 28 07:15:19 2026 +0100

    chore(main): release 0.40.2 (#586)
    '
iq_run "$iq_diff" --recipe commit-message --var recent_commits="$iq_fuller_subject_only" \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '["one_line_exemplar"]' "$(iq_field)" \
  "input-quality: a subject-only fuller entry is flagged despite its header gap"

# 54h3. Subjects separated by blank lines are still subjects only.
iq_run "$iq_diff" --recipe commit-message \
  --var recent_commits=$'fix: typo in README\n\nfeat(cli): add --dry-run\n\nchore(deps): bump jq' \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '["one_line_exemplar"]' "$(iq_field)" \
  "input-quality: a blank-separated subject list is flagged"

# 54h4. A pasted subject and body, no git headers, carries a body.
iq_run "$iq_diff" --recipe commit-message \
  --var recent_commits=$'fix: Loki sync survives bad rows\n\nOne malformed row used to stop the whole sync; it is now skipped.' \
  --var diff_stat=" x.sh | 2 +-" --var why="the cache was cold" prose "go"
assert_eq '"absent"' "$(iq_field)" "input-quality: a pasted subject and body are not flagged"

# 54h4b. A `#N `-prefixed line is a title whatever its wording, so a
# blank-separated list mixing conventional and plain titles is titles-only.
iq_run "" --recipe pr-description \
  --var recent_prs=$'#400 feat(audio): scenes that loop\n\n#399 Arcade music round 2' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq '["titles_only"]' "$(iq_field)" \
  "input-quality: a blank-separated list of #N titles is titles-only"

# 54h5. An envelope whose BODY: is empty carries no body, alone or twice over
# with the blank separator the gather step prints between examples.
iq_run "" --recipe pr-description \
  --var recent_prs=$'<<<EXAMPLE_BEGIN PR #586>>>\nTITLE: chore(main): release 0.40.2\nBODY:\n\n<<<EXAMPLE_END>>>' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq '["titles_only"]' "$(iq_field)" "input-quality: one empty BODY: envelope is titles-only"
iq_run "" --recipe pr-description \
  --var recent_prs=$'<<<EXAMPLE_BEGIN PR #586>>>\nTITLE: chore(main): release 0.40.2\nBODY:\n\n<<<EXAMPLE_END>>>\n\n<<<EXAMPLE_BEGIN PR #580>>>\nTITLE: chore(main): release 0.40.1\nBODY:\n\n<<<EXAMPLE_END>>>' \
  --var diff_stat=" x.sh | 2 +-" --var context="Adds a thing." prose "go"
assert_eq '["titles_only"]' "$(iq_field)" "input-quality: two empty BODY: envelopes are titles-only"

# 54i. The declaration shapes no output, so it is kept out of template_sha:
# adding it did not start a new per-template bucket.
. "$REPO/scripts/lib/recipe.sh"
awk '!/^input_quality:/ && !/^  (recent_commits|stdin): (one_line_exemplar|no_diff)$/' \
  "$REPO/prompts/commit-message.md" > "$tmp/no-iq.md"
if cmp -s "$tmp/no-iq.md" "$REPO/prompts/commit-message.md"; then
  echo "  FAIL  input-quality: commit-message declares no input_quality block"; fail=$((fail+1))
else
  assert_eq "$(recipe_template_sha "$tmp/no-iq.md")" "$(recipe_template_sha "$REPO/prompts/commit-message.md")" \
    "input-quality: the declaration leaves template_sha unchanged"
fi

# 589a. no_title_line: pr-description's output is a body, so a leading
# conventional-commit title line (`type(scope): ...` or `#N type: ...`) is
# stripped when a blank line separates it from the body, like the
# no_padding_tail autofix, and counted as checks_autofixed.
fresh
mk_check_recipe ttl 'no_title_line: true'
mock_curl "$tmp" 'feat(replay): add the gate\n\nThe gate replays each case under both templates.'
err=$(run_recipe ttl)
assert_contains "check 'no_title_line' AUTO-FIXED" "$err" "no_title_line: a type(scope): title line is auto-fixed"
assert_eq "The gate replays each case under both templates." "$(cat "$tmp/stdout")" "no_title_line: the title and its blank line are stripped, the body kept"
assert_contains '"checks_autofixed":1' "$(tail -1 "$metrics")" "no_title_line: the strip is counted on the row"
mock_curl "$tmp" 'feat: add the gate\nThe gate replays each case.'
err=$(run_recipe DELEGATE_NO_RETRY=1 ttl)
assert_contains "check 'no_title_line' FAILED" "$err" "no_title_line: a title glued to the body is reported, not stripped"
assert_contains $'feat: add the gate\nThe gate' "$(cat "$tmp/stdout")" "no_title_line: ...and the output is left as generated"
assert_contains '"checks_failed_names":["no_title_line"]' "$(tail -1 "$metrics")" "no_title_line: the failure is named on the row"

# 589b. no_subject_echo: commit-message's subject copied from an exemplar
# subject — the recipe's own Wrong/Correct lines or a recent_commits entry —
# is rejected. no_example_echo cannot see it: a lone subject normalises under
# its 40-char floor, and a semicolon-joined list of subjects is one line.
mk_check_recipe sub 'no_subject_echo: true' $'Wrong: fix: refresh token before handshake\nCorrect: fix(auth): refresh token before handshake\n=== Recent ===\n{{recent_commits}}' \
  'echo_guard_vars: recent_commits'
mock_curl "$tmp" 'fix(auth): refresh token before handshake\n\nThe token expired mid-handshake.'
err=$(run_recipe DELEGATE_NO_RETRY=1 sub --var recent_commits='3f9e2a1 feat: add the replay gate (#534); 81a3511 fix: store finals after the call (#596)')
assert_contains "check 'no_subject_echo' FAILED" "$err" "no_subject_echo: a subject copied from the recipe's own example fails"
assert_not_contains "no_example_echo' FAILED" "$err" "no_subject_echo: ...which no_example_echo misses under its 40-char floor"
assert_contains '"checks_failed_names":["no_subject_echo"]' "$(tail -1 "$metrics")" "no_subject_echo: the failure is named on the row"

# --- 661. The draft verifier, opt-in on recipe calls: verify-draft.sh runs
# after the checks and any retry, prints one line on a flag, records `verify`
# or `verify_error` on the row, and never changes the draft or the exit code.
fresh
# make_mock_curl_verify DIR DRAFT — dispatches answer DRAFT (JSON-escaped),
# counted in DIR/dcalls; the verifier's logprob requests are counted in
# DIR/vcalls with their argv in DIR/vargv and their payload in DIR/vpayload,
# and give the first option letter the p of the request's SCORE_<p> marker.
# VERIFY_TIMEOUT in the request makes that call exit 28, as --max-time does,
# and NOLETTER answers with neither option letter.
make_mock_curl_verify() {
  local dir="$1"
  printf '{"choices":[{"message":{"content":"%s"},"finish_reason":"stop"}]}' "$2" > "$dir/curl.body"
  : > "$dir/dcalls"; : > "$dir/vcalls"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in */models) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;; esac
done
argv="\$*"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
body=\$(cat)
case "\$body" in
  *'"logprobs":true'*)
    echo x >> "$dir/vcalls"
    printf '%s\n' "\$argv" > "$dir/vargv"
    printf '%s\n' "\$body" > "$dir/vpayload"
    case "\$body" in *VERIFY_TIMEOUT*) echo "curl: (28) Operation timed out" >&2; exit 28 ;; esac
    case "\$body" in *NOLETTER*) echo '{"choices":[{"message":{"content":"Hello"},"logprobs":{"content":[{"token":"Hello","logprob":-0.1,"top_logprobs":[{"token":"Hello","logprob":-0.1}]}]}}]}'; exit 0 ;; esac
    s=\$(printf '%s' "\$body" | grep -o 'SCORE_[0-9.]*' | head -1)
    perl -e 'my \$p = shift || 0.5; my (\$a, \$b) = (log(\$p), log(1 - \$p));
      printf q({"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":%.8f,"top_logprobs":[{"token":"A","logprob":%.8f},{"token":"B","logprob":%.8f}]}]}}]}), \$a, \$a, \$b' "\${s#SCORE_}"
    exit 0 ;;
esac
echo x >> "$dir/dcalls"
if [[ -n "\$out_file" ]]; then cat "$dir/curl.body" > "\$out_file"; else cat "$dir/curl.body"; fi
[[ -n "\$write_out" ]] && printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
exit 0
EOF
  chmod +x "$dir/curl"
}
vcalls() { wc -l < "$tmp/vcalls" | tr -d ' '; }
dcalls() { wc -l < "$tmp/dcalls" | tr -d ' '; }
mk_check_recipe vr '' 'Reply to {{stdin}} for {{who}}.' 'verify: true'
mk_check_recipe unv '' 'Reply to {{stdin}} for {{who}}.'
recipe_stdin='The fix landed in abc123.'

# 661a. A tagged recipe whose draft passes: the row carries verify, the
# stderr carries no flag line, the facts are stdin then the vars in key order.
make_mock_curl_verify "$tmp" 'Fixed in abc123. SCORE_0.9'
err=$(run_recipe DELEGATE_VERIFY_THRESHOLD=0.68 vr --var who=alice --var also=bob)
rc=$?
row=$(tail -1 "$metrics")
assert_eq 0 "$rc" "verify: a passing draft exits 0"
assert_eq 1 "$(vcalls)" "verify: a verify-tagged recipe runs the verifier once"
assert_eq "pass" "$(jq -r '.verify.verdict' <<<"$row")" "verify: the row records verdict pass"
assert_eq "0.9 0.68 qwen3.6:35b-a3b" "$(jq -r '"\(.verify.p_supported) \(.verify.threshold) \(.verify.model)"' <<<"$row")" \
  "verify: the row records p_supported, the threshold and the verifier model"
assert_not_contains "verifier flagged" "$err" "verify: a pass prints no flag line"
assert_contains 'verify="pass"' "$err" "verify: the meta line carries the verdict"
assert_contains '"facts":"The fix landed in abc123.\nbob\nalice"' "$(jq -r '.messages[0].content' "$tmp/vpayload")" \
  "verify: the facts are the piped stdin then each --var value in key order, without the prompt"
assert_contains '--max-time 60 ' "$(cat "$tmp/vargv")" "verify: the verifier call is bounded at 60 s by default"
assert_eq "Fixed in abc123. SCORE_0.9" "$(cat "$tmp/stdout")" "verify: the draft is returned unchanged"
# No threshold recorded or given: verify-draft.sh falls back to 0.5 with a
# note, which the inline path does not print on every call.
err=$(run_recipe vr --var who=alice)
assert_eq "0.5" "$(jq -r '.verify.threshold' <<<"$(tail -1 "$metrics")")" "verify: an uncalibrated model is scored at 0.5"
assert_not_contains "no calibrated threshold" "$err" "verify: the inline path prints no uncalibrated note"

# 661b. A flag: one stderr line, the row says flag, output, exit code and the
# single dispatch unchanged (a flag never earns the retry).
make_mock_curl_verify "$tmp" 'Reverted abc123. SCORE_0.41'
err=$(run_recipe DELEGATE_VERIFY_THRESHOLD=0.68 vr --var who=alice)
rc=$?
assert_eq 0 "$rc" "verify: a flagged draft still exits 0"
assert_eq "Reverted abc123. SCORE_0.41" "$(cat "$tmp/stdout")" "verify: a flagged draft is returned unchanged"
assert_eq 1 "$(dcalls)" "verify: a flag does not trigger the retry"
assert_contains "delegate: verifier flagged a possibly unsupported claim (p_supported=0.41 < 0.68, qwen3.6:35b-a3b)" "$err" \
  "verify: a flag prints one stderr line with p, the threshold and the model"
assert_eq 1 "$(grep -c 'verifier flagged' <<<"$err")" "verify: exactly one flag line"
assert_eq "flag" "$(jq -r '.verify.verdict' <<<"$(tail -1 "$metrics")")" "verify: the row records verdict flag"
assert_contains 'verify="flag"' "$err" "verify: the meta line carries the flag"

# 661c. The verifier fails (a timeout): verify_error on the row, the draft
# and exit code untouched, and DELEGATE_DECIDE_TIMEOUT bounds the call.
make_mock_curl_verify "$tmp" 'Fixed in abc123. VERIFY_TIMEOUT'
err=$(run_recipe DELEGATE_DECIDE_TIMEOUT=7 vr --var who=alice)
rc=$?
row=$(tail -1 "$metrics")
assert_eq 0 "$rc" "verify: a verifier failure leaves the exit code at 0"
assert_eq "Fixed in abc123. VERIFY_TIMEOUT" "$(cat "$tmp/stdout")" "verify: a verifier failure returns the draft"
assert_contains '--max-time 7 ' "$(cat "$tmp/vargv")" "verify: DELEGATE_DECIDE_TIMEOUT bounds the verifier call"
assert_eq "timed out after 7s" "$(jq -r '.verify_error' <<<"$row")" "verify: a timeout is recorded as verify_error"
assert_eq "absent" "$(jq -r '.verify // "absent"' <<<"$row")" "verify: no verify object beside verify_error"
assert_contains "delegate: verifier unavailable (timed out after 7s)" "$err" "verify: the failure is named on stderr"

# 661d. An answer with neither option letter (verify-draft.sh exit 3) is a
# verify_error carrying verify-draft.sh's own reason.
make_mock_curl_verify "$tmp" 'Fixed in abc123. NOLETTER'
err=$(run_recipe vr --var who=alice)
rc=$?
row=$(tail -1 "$metrics")
assert_eq 0 "$rc" "verify: an unscorable answer leaves the exit code at 0"
assert_contains "coverage 0" "$(jq -r '.verify_error' <<<"$row")" "verify: verify-draft's own reason is recorded"
assert_eq "Fixed in abc123. NOLETTER" "$(cat "$tmp/stdout")" "verify: ...and the draft is returned"

# 661e. DELEGATE_VERIFY=0 switches a tagged recipe off.
make_mock_curl_verify "$tmp" 'Fixed in abc123. SCORE_0.41'
err=$(run_recipe DELEGATE_VERIFY=0 vr --var who=alice)
row=$(tail -1 "$metrics")
assert_eq 0 "$(vcalls)" "verify: DELEGATE_VERIFY=0 runs no verifier"
assert_eq "absent absent" "$(jq -r '"\(.verify // "absent") \(.verify_error // "absent")"' <<<"$row")" \
  "verify: DELEGATE_VERIFY=0 leaves both fields off the row"
assert_not_contains 'verify=' "$err" "verify: DELEGATE_VERIFY=0 leaves the meta line alone"

# 661f. An untagged recipe runs nothing; DELEGATE_VERIFY=1 turns it on.
run_recipe unv --var who=alice >/dev/null
assert_eq 0 "$(vcalls)" "verify: an untagged recipe runs no verifier"
assert_eq "absent" "$(jq -r '.verify // "absent"' <<<"$(tail -1 "$metrics")")" "verify: an untagged recipe's row has no verify"
run_recipe DELEGATE_VERIFY=1 DELEGATE_VERIFY_THRESHOLD=0.68 unv --var who=alice >/dev/null
assert_eq 1 "$(vcalls)" "verify: DELEGATE_VERIFY=1 runs the verifier on an untagged recipe"
assert_eq "flag" "$(jq -r '.verify.verdict' <<<"$(tail -1 "$metrics")")" "verify: ...and records its verdict"

# 661g. A bare call never runs it, even with DELEGATE_VERIFY=1.
make_mock_curl_verify "$tmp" 'Fixed in abc123. SCORE_0.41'
printf 'ctx' | env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_VERIFY=1 DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "go" >/dev/null 2>&1
assert_eq 0 "$(vcalls)" "verify: a bare call never runs the verifier"

# 661h. DELEGATE_LOCAL_NO_METRICS=1: still verified and flagged, no row.
: > "$metrics"
err=$(run_recipe DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_VERIFY_THRESHOLD=0.68 vr --var who=alice)
assert_contains "verifier flagged" "$err" "verify: the flag line prints with metrics off"
assert_eq 0 "$(wc -l < "$metrics" | tr -d ' ')" "verify: ...and no row is written"

# 661i. The five reply and description recipes are tagged; commit-message is
# not (its stored inputs lack the diff, so claims read from it look unsupported).
. "$REPO/scripts/lib/recipe.sh"
for r in maintainer-reply maintainer-review-reply pr-description pr-review-reply github-issue-body; do
  assert_eq "true" "$(recipe_verify "$REPO/prompts/$r.md")" "verify: $r is tagged verify: true"
done
assert_eq "" "$(recipe_verify "$REPO/prompts/commit-message.md")" "verify: commit-message is not tagged"
unset recipe_stdin

finish
