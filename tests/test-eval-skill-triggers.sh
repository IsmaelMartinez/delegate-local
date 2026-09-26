#!/usr/bin/env bash
# Unit tests for scripts/eval-skill-triggers.sh. The script issues one
# batched scoring call per run (#62), so the curl mocks parse the queries
# out of the request body and return a verdicts object covering every id.

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

# Build a verdicts object from the request body on stdin. Classifier:
# "perfect" (p→TRIGGER, n→NOTRIGGER), "all-trigger", or "all-trigger-lc"
# ("trigger.\n", for verdict normalisation).
write_classifier_helper() {
  local dir="$1"
  cat > "$dir/build-verdicts.sh" <<'EOF'
#!/usr/bin/env bash
# Reads request body on stdin, classifier rule as $1. Prints verdicts JSON.
# Uses jq to walk the body shape (ollama, anthropic and chat-completions carry
# the user payload as a JSON-encoded string in a different field; we sniff
# each and take the first found).
rule="$1"
body=$(cat)
# Extract the user payload (a JSON-encoded array of {id, query}) from any of:
#   ollama:        .prompt
#   anthropic:     .messages[0].content
#   chat-completions: .messages[1].content (user role, system is at [0])
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
  # $5 optionally restricts which host substring answers GET {base}/models, so
  # a test can prove resolution landed on a specific provider. Empty means
  # every provider answers, which is what most tests want.
  local dir="$1" sniff="$2" backend="$3" rule="$4" models_host="${5:-}"
  write_classifier_helper "$dir"
  local helper="$dir/build-verdicts.sh"
  case "$backend" in
    local)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
body=""
url=""
out="" wfmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) wfmt="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *)  shift ;;
  esac
done
# Discovery: pick-model.sh probes GET {base}/models before any scoring call.
case "\$url" in
  */models)
    if [[ -n "${models_host}" && "\$url" != *"${models_host}"* ]]; then exit 7; fi
    printf '%s' '{"object":"list","data":[{"id":"mock-model:latest"},{"id":"mock-model"},{"id":"explicit-model:99b"},{"id":"qwen3-coder:mock"}]}'
    exit 0
    ;;
esac
printf '%s\n' "\$body" >> "${sniff}"
verdicts=\$(printf '%s' "\$body" | "${helper}" "${rule}")
# Wrap as the model's answer inside the chat-completions envelope.
jq -nc --arg r "\$verdicts" '{choices:[{message:{content:\$r},finish_reason:"stop"}]}' > "\${out:-/dev/stdout}"
if [[ -n "\$wfmt" ]]; then printf 200; fi
EOF
      ;;
    anthropic)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
body=""
out="" wfmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) wfmt="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf '%s\n' "\$body" >> "${sniff}"
verdicts=\$(printf '%s' "\$body" | "${helper}" "${rule}")
jq -nc --arg t "\$verdicts" '{content:[{text:\$t}]}' > "\${out:-/dev/stdout}"
if [[ -n "\$wfmt" ]]; then printf 200; fi
EOF
      ;;
  esac
  chmod +x "$dir/curl"
}

# Mock curl that fails (transport error).
# Serves discovery so resolution succeeds, then fails the scoring call — the
# transport error under test is the scoring call, not the probe.
make_mock_curl_fail() {
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */models) printf '%s' '{"object":"list","data":[{"id":"mock-model"},{"id":"mock-model:latest"}]}'; exit 0 ;;
  esac
done
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

# Mock curl whose scoring call answers with HTTP status $2 and body $3.
# Serves discovery like make_mock_curl_fail; honours -o / -w as real curl
# does, and exits 22 on a non-2xx under -f.
make_mock_curl_status() {
  local dir="$1" code="$2" body="$3"
  printf '%s' "$body" > "$dir/mock-body"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
out="" wfmt="" fail_flag=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    */models) printf '%s' '{"object":"list","data":[{"id":"mock-model"},{"id":"mock-model:latest"}]}'; exit 0 ;;
    -o) out="\$2"; shift 2 ;;
    -w) wfmt="\$2"; shift 2 ;;
    -d|-H|--max-time) shift 2 ;;
    -*f*) [[ "\$1" != --* ]] && fail_flag=1; shift ;;
    *) shift ;;
  esac
done
if [[ "${code}" != 2* && \$fail_flag == 1 ]]; then echo "curl: (22) The requested URL returned error: ${code}" >&2; exit 22; fi
if [[ -n "\$out" ]]; then cat "${dir}/mock-body" > "\$out"; else cat "${dir}/mock-body"; fi
[[ -n "\$wfmt" ]] && printf '%s' "${code}"
exit 0
EOF
  chmod +x "$dir/curl"
}

# Mock pick-model.sh that returns a canned model name.
make_mock_pick_model() {
  # Answers the two surfaces eval-skill-triggers.sh uses: --print-resolution
  # (base + model in one call, for the default path) and --print-providers
  # (the list to walk when a model is named explicitly).
  local dir="$1" model="$2" base="${3:-http://localhost:11434/v1}"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/pick-model.sh" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --print-providers) printf '%s\n' "${base}" ;;
  --print-resolution) printf '%s\t%s\n' "${base}" "${model}" ;;
  *) echo "${model}" ;;
esac
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

# 4. --local with explicit model and a perfect mock curl -> 1.000 / 1.000 pass.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model:latest --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--local perfect mock -> exits 0"
assert_contains "scoring: backend=local model=mock-model:latest" "$out" "--local: model header"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--local perfect: 1.000/1.000"
assert_contains "OK trigger evals (local)" "$out" "--local: OK message"
# Batching: one scoring request for the whole eval set. $sniff records
# scoring bodies only; the discovery probe is not counted.
calls=$(wc -l < "$sniff" | tr -d ' ')
assert_eq 1 "$calls" "--local: exactly one batched scoring call (was $calls)"
rm -rf "$tmp"

# 5. --local with default (pick-model.sh code) resolves a model.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_pick_model "$tmp" "picked-by-tier:42b"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$tmp/scripts/eval-skill-triggers.sh" --local --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--local default -> exits 0"
assert_contains "scoring: backend=local model=picked-by-tier:42b" "$out" "--local default: model from pick-model.sh"
rm -rf "$tmp"

# 6. --local transport error -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_curl_fail "$tmp"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--local transport error -> exit 2"
assert_contains "local transport error" "$out" "--local transport error -> message"
rm -rf "$tmp"

# 7. --local: a bad classifier (always TRIGGER) trips the precision threshold.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local all-trigger
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 1 "$EC" "--local always-TRIGGER -> exit 1 (threshold breach)"
assert_contains "negative-precision=0.000" "$out" "--local always-TRIGGER -> 0 precision"
assert_contains "negative-precision<" "$out" "--local always-TRIGGER -> FAIL precision-side message"
rm -rf "$tmp"

# 8. --local: verdict normalisation (lowercase, trailing newline) still scores.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local all-trigger-lc
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
# All 8 positives counted as TRIGGER (correct) but all 8 negatives also counted as
# TRIGGER (wrong). Recall=1.0, neg-precision=0.0.
assert_contains "recall=1.000 negative-precision=0.000" "$out" "--local: lowercase+punct normalised to TRIGGER"
rm -rf "$tmp"

# 9. --local request body shape: contains the system prompt with the skill description.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local all-trigger
EC=0
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || EC=$?
first_body=$(head -1 "$sniff")
assert_contains '"model":"mock-model"' "$first_body" "--local body: model field"
assert_contains '"role":"system"' "$first_body" "--local body: system message carries the trigger prompt"
assert_contains '"response_format":{"type":"json_object"}' "$first_body" "--local body: JSON mode requested"
assert_contains '"temperature":0' "$first_body" "--local body: temperature:0"
assert_contains '"stream":false' "$first_body" "--local body: stream:false"
# Output budget for 16 queries is 16*30=480.
assert_contains '"max_tokens":480' "$first_body" "--local body: max_tokens scaled to total*30"
assert_contains "delegate-local" "$first_body" "--local body: skill description leaks through"
assert_contains "summarise this log" "$first_body" "--local body: query in prompt"
assert_contains '\"id\":\"p01\"' "$first_body" "--local body: ids in batched payload"
rm -rf "$tmp"

# 10. OLLAMA_HOST steers the scoring call through pick-model.sh's default
# list; only the :9999 provider answers discovery, which proves it.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local all-trigger ":9999"
cat > "$tmp/curl-wrap" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in http*) echo "URL=\$a" >> "$tmp/curl-url-sniff.txt" ;; esac; done
exec "$tmp/curl-real" "\$@"
EOF
mv "$tmp/curl" "$tmp/curl-real"; mv "$tmp/curl-wrap" "$tmp/curl"; chmod +x "$tmp/curl"
: > "$tmp/curl-url-sniff.txt"
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" OLLAMA_HOST=http://other.host:9999 bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || true
urls=$(cat "$tmp/curl-url-sniff.txt")
assert_contains "http://other.host:9999/v1/chat/completions" "$urls" "--local: OLLAMA_HOST steers the scoring call through the default list"
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

# 11b. --api non-200: the status and the start of the body are printed, not
# discarded, so a CI failure names its cause (#548).
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_curl_status "$tmp" 401 '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" ANTHROPIC_API_KEY=sk-bad bash "$SCRIPT" --api --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--api HTTP 401 -> exit 2"
assert_contains "anthropic HTTP 401" "$out" "--api HTTP 401 -> status printed"
assert_contains "invalid x-api-key" "$out" "--api HTTP 401 -> body printed"
rm -rf "$tmp"

# 11c. --api 200 whose body is not the expected JSON (the retired GitHub
# Models host answered every request with 200 text/plain `OK`) is a failure
# with the body shown, never an empty score.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_curl_status "$tmp" 200 'OK'
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" ANTHROPIC_API_KEY=sk-test bash "$SCRIPT" --api --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--api HTTP 200 plain-text body -> exit 2"
assert_contains "anthropic HTTP 200 but the body is not the expected JSON: OK" "$out" "--api HTTP 200 plain-text body -> body shown"
rm -rf "$tmp"

# 11d. --local non-200 goes through the same reporting.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_curl_status "$tmp" 500 'model runner crashed'
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--local HTTP 500 -> exit 2"
assert_contains "local HTTP 500: model runner crashed" "$out" "--local HTTP 500 -> status and body printed"
rm -rf "$tmp"

# 12. --local [model] arg parsing: model captured even when followed by other flags.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
make_mock_curl_batched "$tmp" "$sniff" local perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local explicit-model:99b --skill SKILL.md --eval-set eval-set.json 2>&1) || EC=$?
assert_eq 0 "$EC" "--local with later --skill flag -> exits 0"
assert_contains "model=explicit-model:99b" "$out" "--local: explicit model parsed despite trailing flags"
rm -rf "$tmp"

# 20. Parse-error path: model emits non-JSON garbage -> exit 2.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
# Return a response with no JSON object at all.
make_mock_curl_status "$tmp" 200 '{"choices":[{"message":{"content":"sorry, I cannot help with that."}}]}'
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 2 "$EC" "--local non-JSON response -> exit 2"
assert_contains "did not contain a parseable verdicts array" "$out" "--local non-JSON: parse error message"
rm -rf "$tmp"

# 21. Markdown-fence stripping: model emits ```json ... ``` -> still parses.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
write_classifier_helper "$tmp"
helper="$tmp/build-verdicts.sh"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in
    */models) printf '%s' '{"object":"list","data":[{"id":"mock-model"},{"id":"mock-model:latest"}]}'; exit 0 ;;
  esac
done
body=""
out="" wfmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) wfmt="\$2"; shift 2 ;;
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
verdicts=\$(printf '%s' "\$body" | "$helper" perfect)
fenced="\\\`\\\`\\\`json
\${verdicts}
\\\`\\\`\\\`"
jq -nc --arg r "\$fenced" '{choices:[{message:{content:\$r}}]}' > "\${out:-/dev/stdout}"
if [[ -n "\$wfmt" ]]; then printf 200; fi
EOF
chmod +x "$tmp/curl"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--local fenced JSON -> exits 0"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--local fenced: parses cleanly"
rm -rf "$tmp"

# 22. Missing-verdict path: model only verdicts a subset -> warning + counted as misses.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
# Return only the first 8 (positives); the 8 negatives have no verdict and
# count as fp (NOTRIGGER expected, no verdict received).
make_mock_curl_status "$tmp" 200 '{"choices":[{"message":{"content":"{\"verdicts\":[{\"id\":\"p01\",\"verdict\":\"TRIGGER\"},{\"id\":\"p02\",\"verdict\":\"TRIGGER\"},{\"id\":\"p03\",\"verdict\":\"TRIGGER\"},{\"id\":\"p04\",\"verdict\":\"TRIGGER\"},{\"id\":\"p05\",\"verdict\":\"TRIGGER\"},{\"id\":\"p06\",\"verdict\":\"TRIGGER\"},{\"id\":\"p07\",\"verdict\":\"TRIGGER\"},{\"id\":\"p08\",\"verdict\":\"TRIGGER\"}]}"}}]}'
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
# 8 positives correctly TRIGGER (recall=1.0), 8 negatives missing → counted as fp (neg-precision=0).
assert_contains "8 verdicts missing" "$out" "--local partial: warning surfaces missing count"
assert_contains "recall=1.000 negative-precision=0.000" "$out" "--local partial: missing counted as misses"
rm -rf "$tmp"

# N. gate:false diagnostic queries (#277) are scored and reported but not
# gated: one diagnostic miss would otherwise drop recall below 0.9.
tmp=$(mktemp -d)
make_skill "$tmp"
make_eval_set "$tmp"
# Append two diagnostic entries to the fixture's queries array.
jq '.queries += [
  {"id":"p90","tag":"embedded","expect":"trigger","gate":false,"query":"implement X then commit and open a PR"},
  {"id":"e01","tag":"embedded","expect":"trigger","gate":false,"query":"fix the bug then commit and push"}
]' "$tmp/eval-set.json" > "$tmp/eval-set.json.new" && mv "$tmp/eval-set.json.new" "$tmp/eval-set.json"
sniff="$tmp/body.txt"
make_mock_curl_batched "$tmp" "$sniff" local perfect
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --local mock-model:latest --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "gate:false: gating still passes (exit 0)"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "gate:false: diagnostics excluded from gating recall"
assert_contains "diagnostic (non-gating, embedded sub-step): dtp=1 dfn=1 embedded-recall=0.500" "$out" "gate:false: diagnostic line reports embedded-recall"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
