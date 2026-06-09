#!/usr/bin/env bash
# Unit tests for scripts/eval-skill-triggers.sh.
# Mocks `curl` (Ollama, Anthropic, GitHub Models backends) and optionally
# `pick-model.sh` on a restricted PATH so the test runs the same everywhere.
#
# The script under test issues exactly one batched scoring call per run
# (issue #62 quota fix). Mocks therefore parse the queries out of the
# request body and return a verdicts JSON object covering every id, rather
# than answering per-query like the pre-batching version.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/eval-skill-triggers.sh"
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
  else echo "  FAIL  $name (missing '$needle' in '$haystack')"; fail=$((fail+1)); fi
}

# Build a minimal eval-set fixture in $1/eval-set.json with 8 positives and
# 8 negatives. Ids start with `p` for positives and `n` for negatives — mocks
# rely on the prefix to classify in the perfect-classifier path.
make_eval_set() {
  local dir="$1"
  cat > "$dir/eval-set.json" <<'JSON'
{
  "skill": "delegate-local",
  "model": "claude-sonnet-4-6",
  "thresholds": {"positive_recall": 0.9, "negative_precision": 0.9},
  "queries": [
    {"id":"p01","tag":"exact","expect":"trigger","query":"summarise this log"},
    {"id":"p02","tag":"exact","expect":"trigger","query":"summarise this diff"},
    {"id":"p03","tag":"exact","expect":"trigger","query":"summarise this PR"},
    {"id":"p04","tag":"exact","expect":"trigger","query":"summarise this file"},
    {"id":"p05","tag":"exact","expect":"trigger","query":"draft a commit message"},
    {"id":"p06","tag":"exact","expect":"trigger","query":"draft a release note"},
    {"id":"p07","tag":"exact","expect":"trigger","query":"draft a changelog"},
    {"id":"p08","tag":"exact","expect":"trigger","query":"triage these tickets"},
    {"id":"n01","tag":"adjacent","expect":"no-trigger","query":"why is this test flaky"},
    {"id":"n02","tag":"adjacent","expect":"no-trigger","query":"design a database schema"},
    {"id":"n03","tag":"adjacent","expect":"no-trigger","query":"review this PR for security"},
    {"id":"n04","tag":"adjacent","expect":"no-trigger","query":"trace why useInvoices returns undefined"},
    {"id":"n05","tag":"unrelated","expect":"no-trigger","query":"what is the difference between spirit and liqueur"},
    {"id":"n06","tag":"unrelated","expect":"no-trigger","query":"my dog chews the rug"},
    {"id":"n07","tag":"adjacent","expect":"no-trigger","query":"refactor this class into two"},
    {"id":"n08","tag":"adjacent","expect":"no-trigger","query":"is there a vulnerability in this jwt"}
  ]
}
JSON
}

# Mock SKILL.md fixture with a parseable description.
make_skill() {
  local dir="$1"
  cat > "$dir/SKILL.md" <<'MD'
---
name: delegate-local
description: Use this skill to offload non-reasoning text work to local Ollama models. MUST use when the user asks to summarise, draft, triage, classify, extract, or rewrite text. Do NOT use for code correctness review or debugging.
---

# Body
MD
}

# Build a verdicts JSON object given the request body and a classifier rule.
# The classifier is one of:
#   "perfect"        — id prefix p → TRIGGER, n → NOTRIGGER
#   "all-trigger"    — every id → TRIGGER
#   "all-trigger-lc" — every id → "trigger.\n" (tests verdict normalisation)
# Reads the body from stdin, prints the verdicts JSON object on stdout.
# Uses jq + grep, both available on SAFE_PATH on Ubuntu and macOS.
write_classifier_helper() {
  local dir="$1"
  cat > "$dir/build-verdicts.sh" <<'EOF'
#!/usr/bin/env bash
# Reads request body on stdin, classifier rule as $1. Prints verdicts JSON.
# Uses jq to walk the body shape (ollama, anthropic, github_models all carry
# the user payload as a JSON-encoded string in a different field; we sniff
# all three and union the ids found).
rule="$1"
body=$(cat)
# Extract the user payload (a JSON-encoded array of {id, query}) from any of:
#   ollama:        .prompt
#   anthropic:     .messages[0].content
#   github_models: .messages[1].content (user role, system is at [0])
# Fall back to scanning all messages when shapes vary.
payload=$(jq -r '
  .prompt //
  (.messages // [] | map(select(.role == "user") | .content) | first) //
  empty
' <<<"$body" 2>/dev/null)
[[ -z "$payload" ]] && { echo "build-verdicts: could not find user payload in body" >&2; exit 1; }
# Parse the payload as JSON and emit verdicts per id.
case "$rule" in
  perfect)
    jq -c '{verdicts: (. | map({id: .id, verdict: (if (.id | startswith("p")) then "TRIGGER" else "NOTRIGGER" end)}))}' <<<"$payload"
    ;;
  all-trigger)
    jq -c '{verdicts: (. | map({id: .id, verdict: "TRIGGER"}))}' <<<"$payload"
    ;;
  all-trigger-lc)
    # Lowercase verdict with trailing punctuation+newline; the script must
    # normalise it back to TRIGGER.
    jq -c '{verdicts: (. | map({id: .id, verdict: "trigger.\n"}))}' <<<"$payload"
    ;;
  *)
    echo "unknown classifier rule: $rule" >&2; exit 1 ;;
esac
EOF
  chmod +x "$dir/build-verdicts.sh"
}

# Mock curl that emits one batched response per invocation. Captures body to
# $sniff and selects verdicts via the classifier rule.
make_mock_curl_batched() {
  local dir="$1" sniff="$2" backend="$3" rule="$4"
  write_classifier_helper "$dir"
  local helper="$dir/build-verdicts.sh"
  case "$backend" in
    ollama)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf '%s\n' "\$body" >> "${sniff}"
verdicts=\$(printf '%s' "\$body" | "${helper}" "${rule}")
# Wrap as the model's text response inside the ollama envelope.
jq -nc --arg r "\$verdicts" '{response: \$r}'
EOF
      ;;
    anthropic)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf '%s\n' "\$body" >> "${sniff}"
verdicts=\$(printf '%s' "\$body" | "${helper}" "${rule}")
jq -nc --arg t "\$verdicts" '{content:[{text:\$t}]}'
EOF
      ;;
    github_models)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
body="" out_file="" headers_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf '%s\n' "\$body" >> "${sniff}"
verdicts=\$(printf '%s' "\$body" | "${helper}" "${rule}")
jq -nc --arg c "\$verdicts" '{choices:[{message:{content:\$c}}]}' > "\$out_file"
: > "\$headers_file"
printf '200'
EOF
      ;;
  esac
  chmod +x "$dir/curl"
}

# Mock curl that fails (transport error).
make_mock_curl_fail() {
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

# Mock pick-model.sh that returns a canned model name.
make_mock_pick_model() {
  local dir="$1" model="$2"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/pick-model.sh" <<EOF
#!/usr/bin/env bash
echo "${model}"
EOF
  chmod +x "$dir/scripts/pick-model.sh"
  cp "$SCRIPT" "$dir/scripts/eval-skill-triggers.sh"
}

# 1. usage: bad flag -> exit 2.
EC=0
out=$(bash "$SCRIPT" --bogus 2>&1) || EC=$?
assert_eq 2 "$EC" "bad flag -> exit 2"
assert_contains "usage:" "$out" "bad flag -> usage line"

# 2. shape mode: prints summary and exits 0.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
EC=0
out=$(cd "$tmp" && bash "$SCRIPT" --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "shape: exits 0"
assert_contains "shape: total=16 positive=8 negative=8" "$out" "shape: counts emitted"
assert_contains "OK shape mode" "$out" "shape: OK message"
rm -rf "$tmp"

# 3. --api with no key -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
EC=0
out=$(cd "$tmp" && env -i PATH="$SAFE_PATH" bash "$SCRIPT" --api --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--api without key -> exit 2"
assert_contains "ANTHROPIC_API_KEY not set" "$out" "--api without key -> error message"
rm -rf "$tmp"

# 4. --ollama with explicit model and a perfect mock curl -> 1.000 / 1.000 pass.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model:latest --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama perfect mock -> exits 0"
assert_contains "scoring: backend=ollama model=mock-model:latest" "$out" "--ollama: model header"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--ollama perfect: 1.000/1.000"
assert_contains "OK trigger evals (ollama)" "$out" "--ollama: OK message"
# Assert exactly one curl call was made (batching).
calls=$(wc -l < "$sniff" | tr -d ' ')
assert_eq 1 "$calls" "--ollama: exactly one batched call (was $calls)"
rm -rf "$tmp"

# 5. --ollama with default (pick-model.sh code) resolves a model.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_pick_model "$tmp" "picked-by-tier:42b"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$tmp/scripts/eval-skill-triggers.sh" --ollama --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama default -> exits 0"
assert_contains "scoring: backend=ollama model=picked-by-tier:42b" "$out" "--ollama default: model from pick-model.sh"
rm -rf "$tmp"

# 6. --ollama transport error -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_curl_fail "$tmp"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--ollama transport error -> exit 2"
assert_contains "ollama transport error" "$out" "--ollama transport error -> message"
rm -rf "$tmp"

# 7. --ollama: a bad classifier (always TRIGGER) trips the precision threshold.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama all-trigger
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 1 "$EC" "--ollama always-TRIGGER -> exit 1 (threshold breach)"
assert_contains "negative-precision=0.000" "$out" "--ollama always-TRIGGER -> 0 precision"
assert_contains "negative-precision<" "$out" "--ollama always-TRIGGER -> FAIL precision-side message"
rm -rf "$tmp"

# 8. --ollama: verdict normalisation (lowercase, trailing newline) still scores.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama all-trigger-lc
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
# All 8 positives counted as TRIGGER (correct) but all 8 negatives also counted as
# TRIGGER (wrong). Recall=1.0, neg-precision=0.0.
assert_contains "recall=1.000 negative-precision=0.000" "$out" "--ollama: lowercase+punct normalised to TRIGGER"
rm -rf "$tmp"

# 9. --ollama request body shape: contains the system prompt with the skill description.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama all-trigger
EC=0
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || EC=$?
first_body=$(head -1 "$sniff")
assert_contains '"model":"mock-model"' "$first_body" "--ollama body: model field"
assert_contains '"think":false' "$first_body" "--ollama body: think:false"
assert_contains '"format":"json"' "$first_body" "--ollama body: format:json (batched JSON output)"
assert_contains '"temperature":0' "$first_body" "--ollama body: temperature:0"
assert_contains '"stream":false' "$first_body" "--ollama body: stream:false"
assert_contains "delegate-local" "$first_body" "--ollama body: skill description leaks through"
assert_contains "summarise this log" "$first_body" "--ollama body: query in prompt"
assert_contains '\"id\":\"p01\"' "$first_body" "--ollama body: ids in batched payload"
rm -rf "$tmp"

# 10. OLLAMA_HOST env override is honoured.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
write_classifier_helper "$tmp"
helper="$tmp/build-verdicts.sh"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url="" body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) body="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
echo "URL=\$url" >> "$tmp/curl-url-sniff.txt"
verdicts=\$(printf '%s' "\$body" | "$helper" all-trigger)
jq -nc --arg r "\$verdicts" '{response: \$r}'
EOF
chmod +x "$tmp/curl"
: > "$tmp/curl-url-sniff.txt"
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" OLLAMA_HOST=http://other.host:9999 bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || true
url_line=$(head -1 "$tmp/curl-url-sniff.txt")
assert_contains "http://other.host:9999/api/generate" "$url_line" "--ollama: OLLAMA_HOST override honoured"
rm -rf "$tmp"

# 11. --api backend hits Anthropic endpoint with a perfect classifier and the key header.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" anthropic perfect
mv "$tmp/curl" "$tmp/curl-real"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
echo "URL=\$url" >> "$tmp/url-sniff.txt"
exec "$tmp/curl-real" "\$@"
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" ANTHROPIC_API_KEY=sk-test bash "$SCRIPT" --api --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--api perfect mock -> exits 0"
assert_contains "scoring: backend=anthropic" "$out" "--api: backend label"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--api perfect: 1.000/1.000"
url_line=$(head -1 "$tmp/url-sniff.txt")
assert_contains "https://api.anthropic.com/v1/messages" "$url_line" "--api: hits Anthropic URL"
rm -rf "$tmp"

# 12. --ollama [model] arg parsing: model captured even when followed by other flags.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama explicit-model:99b --skill SKILL.md --eval-set eval-set.json 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama with later --skill flag -> exits 0"
assert_contains "model=explicit-model:99b" "$out" "--ollama: explicit model parsed despite trailing flags"
rm -rf "$tmp"

# 13. --github-models with no GITHUB_TOKEN -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
EC=0
out=$(cd "$tmp" && env -i PATH="$SAFE_PATH" bash "$SCRIPT" --github-models --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--github-models without token -> exit 2"
assert_contains "GITHUB_TOKEN not set" "$out" "--github-models without token -> error message"
rm -rf "$tmp"

# 14. --github-models with explicit model and a perfect mock curl -> 1.000 / 1.000 pass.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" github_models perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test bash "$SCRIPT" --github-models openai/gpt-4o-mini --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--github-models perfect mock -> exits 0"
assert_contains "scoring: backend=github_models model=openai/gpt-4o-mini" "$out" "--github-models: model header"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--github-models perfect: 1.000/1.000"
assert_contains "OK trigger evals (github_models)" "$out" "--github-models: OK message"
calls=$(wc -l < "$sniff" | tr -d ' ')
assert_eq 1 "$calls" "--github-models: exactly one batched call (was $calls)"
rm -rf "$tmp"

# 15. --github-models default model is openai/gpt-4o-mini.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" github_models perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test bash "$SCRIPT" --github-models --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--github-models default -> exits 0"
assert_contains "model=openai/gpt-4o-mini" "$out" "--github-models default: openai/gpt-4o-mini"
rm -rf "$tmp"

# 16. --github-models request body shape: model, messages array (system+user), temperature, max_tokens scaled, response_format JSON.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" github_models perfect
EC=0
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test bash "$SCRIPT" --github-models test-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || EC=$?
first_body=$(head -1 "$sniff")
assert_contains '"model":"test-model"' "$first_body" "--github-models body: model field"
assert_contains '"role":"system"' "$first_body" "--github-models body: system role in messages"
assert_contains '"role":"user"' "$first_body" "--github-models body: user role in messages"
assert_contains '"temperature":0' "$first_body" "--github-models body: temperature:0"
# Output budget for 16 queries is 16*30=480.
assert_contains '"max_tokens":480' "$first_body" "--github-models body: max_tokens scaled to total*30"
assert_contains '"response_format":{"type":"json_object"}' "$first_body" "--github-models body: JSON output mode"
assert_contains "summarise this log" "$first_body" "--github-models body: query in user message"
rm -rf "$tmp"

# 17. --github-models honours GITHUB_MODELS_HOST override.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
write_classifier_helper "$tmp"
helper="$tmp/build-verdicts.sh"
url_sniff_file="$tmp/url-sniff.txt"
: > "$url_sniff_file"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url="" out_file="" headers_file="" body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
echo "URL=\$url" >> "$url_sniff_file"
verdicts=\$(printf '%s' "\$body" | "$helper" all-trigger)
jq -nc --arg c "\$verdicts" '{choices:[{message:{content:\$c}}]}' > "\$out_file"
: > "\$headers_file"
printf '200'
EOF
chmod +x "$tmp/curl"
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test GITHUB_MODELS_HOST=https://other.host:8080 bash "$SCRIPT" --github-models test-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || true
url_line=$(head -1 "$url_sniff_file" 2>/dev/null)
assert_contains "https://other.host:8080/inference/chat/completions" "$url_line" "--github-models: GITHUB_MODELS_HOST override honoured"
rm -rf "$tmp"

# 18. --github-models retry-after handling: 429 once, then 200 -> succeeds. Counter goes to 2 (one retry + the one batched call).
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
write_classifier_helper "$tmp"
helper="$tmp/build-verdicts.sh"
counter="$tmp/call-counter"
echo 0 > "$counter"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
out_file="" headers_file="" body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -D) headers_file="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
n=\$(cat "$counter")
echo \$((n+1)) > "$counter"
if [[ "\$n" == "0" ]]; then
  : > "\$out_file"
  printf 'HTTP/2 429\r\nretry-after: 1\r\n\r\n' > "\$headers_file"
  printf '429'
else
  verdicts=\$(printf '%s' "\$body" | "$helper" all-trigger)
  jq -nc --arg c "\$verdicts" '{choices:[{message:{content:\$c}}]}' > "\$out_file"
  : > "\$headers_file"
  printf '200'
fi
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test bash "$SCRIPT" --github-models test-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_contains "scoring: backend=github_models" "$out" "--github-models 429-then-200: reached scoring"
final_count=$(cat "$counter")
[[ "$final_count" -eq "2" ]] && pass=$((pass+1)) && echo "  PASS  --github-models 429: retried (counter == 2 = 1 retry + 1 batched call)" || { fail=$((fail+1)); echo "  FAIL  --github-models 429: counter=$final_count expected 2"; }
rm -rf "$tmp"

# 19. --github-models with bad flag arrangement still parses model.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" github_models perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" GITHUB_TOKEN=ghs_test bash "$SCRIPT" --github-models special/model:v9 --skill SKILL.md --eval-set eval-set.json 2>&1) || EC=$?
assert_eq 0 "$EC" "--github-models with later --skill flag -> exits 0"
assert_contains "model=special/model:v9" "$out" "--github-models: explicit model parsed despite trailing flags"
rm -rf "$tmp"

# 20. Parse-error path: model emits non-JSON garbage -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
# Return a response with no JSON object at all.
printf '%s' '{"response":"sorry, I cannot help with that."}'
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--ollama non-JSON response -> exit 2"
assert_contains "did not contain a parseable verdicts array" "$out" "--ollama non-JSON: parse error message"
rm -rf "$tmp"

# 21. Markdown-fence stripping: model emits ```json ... ``` -> still parses.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
write_classifier_helper "$tmp"
helper="$tmp/build-verdicts.sh"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
verdicts=\$(printf '%s' "\$body" | "$helper" perfect)
fenced="\\\`\\\`\\\`json
\${verdicts}
\\\`\\\`\\\`"
jq -nc --arg r "\$fenced" '{response: \$r}'
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama fenced JSON -> exits 0"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--ollama fenced: parses cleanly"
rm -rf "$tmp"

# 22. Missing-verdict path: model only verdicts a subset -> warning + counted as misses.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
# Return only the first 8 (positives); the 8 negatives have no verdict and
# count as fp (NOTRIGGER expected, no verdict received).
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"response":"{\"verdicts\":[{\"id\":\"p01\",\"verdict\":\"TRIGGER\"},{\"id\":\"p02\",\"verdict\":\"TRIGGER\"},{\"id\":\"p03\",\"verdict\":\"TRIGGER\"},{\"id\":\"p04\",\"verdict\":\"TRIGGER\"},{\"id\":\"p05\",\"verdict\":\"TRIGGER\"},{\"id\":\"p06\",\"verdict\":\"TRIGGER\"},{\"id\":\"p07\",\"verdict\":\"TRIGGER\"},{\"id\":\"p08\",\"verdict\":\"TRIGGER\"}]}"}'
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
# 8 positives correctly TRIGGER (recall=1.0), 8 negatives missing → counted as fp (neg-precision=0).
assert_contains "8 verdicts missing" "$out" "--ollama partial: warning surfaces missing count"
assert_contains "recall=1.000 negative-precision=0.000" "$out" "--ollama partial: missing counted as misses"
rm -rf "$tmp"

# N. gate:false diagnostic queries (#277 dir 3) are scored and reported but
# excluded from the pass/fail recall gate. The fixture adds two diagnostic
# positives: one the perfect classifier marks TRIGGER (id starts with p) and
# one it marks NOTRIGGER (a miss). If diagnostics counted toward the gate the
# miss would drop gating recall below 0.9 and the run would exit 1; instead
# gating stays 1.000/exit 0 and the diagnostic line reports embedded-recall.
tmp=$(mktemp -d)
make_skill "$tmp"
make_eval_set "$tmp"
# Append two diagnostic entries to the fixture's queries array.
jq '.queries += [
  {"id":"p90","tag":"embedded","expect":"trigger","gate":false,"query":"implement X then commit and open a PR"},
  {"id":"e01","tag":"embedded","expect":"trigger","gate":false,"query":"fix the bug then commit and push"}
]' "$tmp/eval-set.json" > "$tmp/eval-set.json.new" && mv "$tmp/eval-set.json.new" "$tmp/eval-set.json"
sniff="$tmp/body.txt"
make_mock_curl_batched "$tmp" "$sniff" ollama perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model:latest --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "gate:false: gating still passes (exit 0)"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "gate:false: diagnostics excluded from gating recall"
assert_contains "diagnostic (non-gating, embedded sub-step): dtp=1 dfn=1 embedded-recall=0.500" "$out" "gate:false: diagnostic line reports embedded-recall"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
