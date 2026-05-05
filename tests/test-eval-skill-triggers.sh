#!/usr/bin/env bash
# Unit tests for scripts/eval-skill-triggers.sh.
# Mocks `curl` (Ollama and Anthropic backends) and optionally `pick-model.sh`
# on a restricted PATH so the test runs the same everywhere.

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

# Build a minimal eval-set fixture in $1/eval-set.json with two positives and
# two negatives. The shape check requires >=8 of each, so we override the
# threshold gate by writing 8 of each (8 trigger, 8 no-trigger) but only the
# verdict field matters for the per-query scoring tests.
make_eval_set() {
  local dir="$1"
  cat > "$dir/eval-set.json" <<'JSON'
{
  "skill": "delegate-to-ollama",
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
name: delegate-to-ollama
description: Use this skill to offload non-reasoning text work to local Ollama models. MUST use when the user asks to summarise, draft, triage, classify, extract, or rewrite text. Do NOT use for code correctness review or debugging.
---

# Body
MD
}

# Mock curl that returns a canned response. The mock writes the JSON body it
# was given to $sniff for assertions.
make_mock_curl_canned() {
  local dir="$1" sniff="$2" backend="$3" verdict="$4"
  case "$backend" in
    ollama)
      cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
# Capture the last -d argument (request body) by walking argv.
body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf '%s\n' "\$body" >> "${sniff}"
printf '%s' '{"response":"${verdict}"}'
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
printf '%s' '{"content":[{"text":"${verdict}"}]}'
EOF
      ;;
  esac
  chmod +x "$dir/curl"
}

# Mock curl that returns different verdict per query. The verdict logic
# inspects the request body for the query string and picks "TRIGGER" or
# "NOTRIGGER" based on whether the id starts with p (positive) or n (negative).
# This lets us test recall/precision math with a perfect classifier.
make_mock_curl_perfect() {
  local dir="$1" backend="$2"
  case "$backend" in
    ollama)
      cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# Extract just the user's prompt field — the system prompt contains the
# trigger keywords too, so matching the whole body would misclassify
# negatives. Compact JSON shape: ..."prompt":"<query>"...
prompt_value=$(printf '%s' "$body" | sed -nE 's/.*"prompt":"([^"]*)".*/\1/p')
if [[ "$prompt_value" == *summarise* || "$prompt_value" == *draft* || "$prompt_value" == *triage* || "$prompt_value" == *classify* ]]; then
  printf '%s' '{"response":"TRIGGER"}'
else
  printf '%s' '{"response":"NOTRIGGER"}'
fi
EOF
      ;;
    anthropic)
      cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# Anthropic body shape: ..."content":"<query>"... (the user's query rides
# inside the messages array as the only user-role content).
content_value=$(printf '%s' "$body" | sed -nE 's/.*"content":"([^"]*)".*/\1/p')
if [[ "$content_value" == *summarise* || "$content_value" == *draft* || "$content_value" == *triage* || "$content_value" == *classify* ]]; then
  printf '%s' '{"content":[{"text":"TRIGGER"}]}'
else
  printf '%s' '{"content":[{"text":"NOTRIGGER"}]}'
fi
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

# Mock pick-model.sh that returns a canned model name. Used when testing
# the default resolution path. The script lives outside the repo so the real
# pick-model.sh is shadowed; we redirect the call inside the test by passing
# --skill / --eval-set paths and exporting a wrapper script directory.
make_mock_pick_model() {
  local dir="$1" model="$2"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/pick-model.sh" <<EOF
#!/usr/bin/env bash
echo "${model}"
EOF
  chmod +x "$dir/scripts/pick-model.sh"
  # eval-skill-triggers.sh resolves pick-model.sh relative to its own dirname,
  # so we copy the script under test into the same dir.
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
make_mock_curl_perfect "$tmp" ollama
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model:latest --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama perfect mock -> exits 0"
assert_contains "scoring: backend=ollama model=mock-model:latest" "$out" "--ollama: model header"
assert_contains "recall=1.000 negative-precision=1.000" "$out" "--ollama perfect: 1.000/1.000"
assert_contains "OK trigger evals (ollama)" "$out" "--ollama: OK message"
rm -rf "$tmp"

# 5. --ollama with default (pick-model.sh code) resolves a model.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
make_mock_pick_model "$tmp" "picked-by-tier:42b"
make_mock_curl_perfect "$tmp" ollama
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
make_mock_curl_canned "$tmp" "$sniff" ollama "TRIGGER"
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md 2>&1) || EC=$?
assert_eq 1 "$EC" "--ollama always-TRIGGER -> exit 1 (threshold breach)"
assert_contains "negative-precision=0.000" "$out" "--ollama always-TRIGGER -> 0 precision"
assert_contains "FAIL: recall<" "$out" "--ollama always-TRIGGER -> FAIL message"
rm -rf "$tmp"

# 8. --ollama: verdict normalisation (lowercase, trailing newline) still scores.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
sniff="$tmp/sniff.txt"
# Lowercase trigger with trailing newline and punctuation; should still match.
make_mock_curl_canned "$tmp" "$sniff" ollama "trigger.\n"
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
make_mock_curl_canned "$tmp" "$sniff" ollama "TRIGGER"
EC=0
(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama mock-model --eval-set eval-set.json --skill SKILL.md >/dev/null 2>&1) || EC=$?
# Sniff first request body and assert key fields.
first_body=$(head -1 "$sniff")
assert_contains '"model":"mock-model"' "$first_body" "--ollama body: model field"
assert_contains '"think":false' "$first_body" "--ollama body: think:false"
assert_contains '"temperature":0' "$first_body" "--ollama body: temperature:0"
assert_contains '"stream":false' "$first_body" "--ollama body: stream:false"
assert_contains "delegate-to-ollama" "$first_body" "--ollama body: skill description leaks through"
assert_contains "summarise this log" "$first_body" "--ollama body: query in prompt"
rm -rf "$tmp"

# 10. OLLAMA_HOST env override is honoured.
tmp=$(mktemp -d)
make_eval_set "$tmp"
make_skill "$tmp"
# Wrap curl so the URL it received is logged. The sniff file lives inside
# the per-test temp dir so concurrent runs of this test (or any other)
# cannot collide on a shared /tmp path.
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do
  case "\$a" in
    http*) url="\$a" ;;
  esac
done
echo "URL=\$url" >> "$tmp/curl-url-sniff.txt"
printf '%s' '{"response":"TRIGGER"}'
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
make_mock_curl_perfect "$tmp" anthropic
# Wrap to capture URL alongside the perfect classifier.
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
make_mock_curl_perfect "$tmp" ollama
EC=0
out=$(cd "$tmp" && PATH="$tmp:$SAFE_PATH" bash "$SCRIPT" --ollama explicit-model:99b --skill SKILL.md --eval-set eval-set.json 2>&1) || EC=$?
assert_eq 0 "$EC" "--ollama with later --skill flag -> exits 0"
assert_contains "model=explicit-model:99b" "$out" "--ollama: explicit model parsed despite trailing flags"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
