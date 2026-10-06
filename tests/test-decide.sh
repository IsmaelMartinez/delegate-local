#!/usr/bin/env bash
# Unit tests for scripts/decide.sh (#636). A mock `curl` on a restricted PATH
# answers discovery, the Clef /v1/systemone endpoint and chat/completions.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
SCRIPT="$REPO/scripts/decide.sh"

mock=$(mktemp -d)
sniff="$mock/payloads"
: > "$sniff"
# Clef answers in SystemOne shape; the control's first token has A at 0.6,
# a byte-level " B" at 0.3 and an unrelated token at 0.05.
cat > "$mock/clef.json" <<'EOF'
{"model":"clef-flash","answers":{
 "outage":{"type":"noul","noul":0.8},
 "department":{"type":"choice","choice":"technical","confidence":0.9,"probabilities":{"billing":0.1,"technical":0.9}},
 "urgency":{"type":"score","score":1.8,"confidence":0.8,"legend":{"0":"Can wait","1":"This week","2":"Today"},"probabilities":{"0":0.05,"1":0.1,"2":0.85}}},
 "usage":{"input_tokens":42,"output_tokens":0}}
EOF
cat > "$mock/chat.json" <<'EOF'
{"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":-0.5108,
 "top_logprobs":[{"token":"A","logprob":-0.5108},{"token":"ĠB","logprob":-1.2040},{"token":"Hello","logprob":-2.9957}]}]}}]}
EOF
cat > "$mock/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */models) printf '%s' '$(mock_models_json "$MOCK_MODELS")' ;;
  */v1/systemone)
    cat >> "$sniff"
    [[ -f "$mock/clef-down" ]] && { echo 'connection refused' ; exit 7; }
    cat "$mock/clef.json" ;;
  */chat/completions) cat >> "$sniff"; cat "$mock/chat.json" ;;
esac
EOF
chmod +x "$mock/curl"
cleanup_on_exit "$mock"

run() { PATH="$mock:$SAFE_PATH" bash "$SCRIPT" "$@"; }

request='{"state":"Checkout returns errors and orders are blocked.",
 "questions":{
  "department":{"type":"choice","instructions":"Which team?","criteria":{"technical":"Bugs or outages","billing":"Payments"}},
  "urgency":{"type":"score","criteria":["Can wait","This week","Today"]},
  "outage":{"type":"noul","instructions":"Is a service down?"}}}'

echo "clef backend"
out=$(run --backend clef <<<"$request")
assert_eq "0.8" "$(jq -r '.answers.outage.probabilities.true' <<<"$out")" "noul becomes a true probability"
assert_eq "0.2" "$(jq -r '.answers.outage.probabilities.false | . * 10 | round / 10' <<<"$out")" "noul false is the complement"
assert_eq "0.9" "$(jq -r '.answers.department.probabilities.technical' <<<"$out")" "choice probabilities pass through"
assert_eq "0.85" "$(jq -r '.answers.urgency.probabilities["2"]' <<<"$out")" "score probabilities keyed by level"
assert_eq "clef" "$(jq -r '.backend' <<<"$out")" "backend labelled clef"
assert_eq "number" "$(jq -r '.latency_ms | type' <<<"$out")" "latency recorded"
assert_contains '"model":"clef-flash"' "$(tail -1 "$sniff")" "default model injected into the request"

echo "logprob backend"
: > "$sniff"
out=$(run --backend logprob <<<"$request")
assert_eq "logprob" "$(jq -r '.backend' <<<"$out")" "backend labelled logprob"
assert_eq "qwen3.6:35b-a3b" "$(jq -r '.model' <<<"$out")" "model comes from pick-model"
assert_eq "0.6667" "$(jq -r '.answers.outage.probabilities.true' <<<"$out")" "A renormalised over the option letters"
assert_eq "0.3333" "$(jq -r '.answers.outage.probabilities.false' <<<"$out")" "byte-level ' B' token counted for B"
assert_eq "0.9" "$(jq -r '.answers.outage.coverage' <<<"$out")" "coverage is the raw letter mass"
assert_eq "0" "$(jq -r '.answers.urgency.probabilities["2"]' <<<"$out")" "an option absent from top logprobs scores 0"
assert_eq "3" "$(wc -l < "$sniff" | tr -d ' ')" "one call per question"
first=$(head -1 "$sniff")
assert_contains 'A: billing' "$(jq -r '.messages[0].content' <<<"$first")" "choice options sorted, billing first"
assert_contains 'B: technical' "$(jq -r '.messages[0].content' <<<"$first")" "technical lettered B"
assert_eq "1" "$(jq -r '.max_tokens' <<<"$first")" "one token generated"
assert_eq "10" "$(jq -r '.top_logprobs' <<<"$first")" "top_logprobs within mlx_lm.server's limit"
assert_eq "false" "$(jq -r '.chat_template_kwargs.enable_thinking' <<<"$first")" "thinking disabled"

echo "errors"
run --backend clef <<<'{"state":"x","questions":{}}' >/dev/null 2>&1
assert_eq "2" "$?" "a request without questions exits 2"
run --backend nope <<<"$request" >/dev/null 2>&1
assert_eq "2" "$?" "an unknown backend exits 2"
many=$(jq -nc '{state:"x",questions:{q:{type:"choice",criteria:([range(27)] | map({key:"o\(.)",value:"v"}) | from_entries)}}}')
err=$(run --backend logprob <<<"$many" 2>&1 >/dev/null)
assert_contains "needs 2-26" "$err" "more than 26 options is refused by the control"
touch "$mock/clef-down"
err=$(run --backend clef <<<"$request" 2>&1 >/dev/null)
rc=$?
assert_eq "1" "$rc" "an unreachable Clef endpoint exits 1"
assert_contains "clef request to" "$err" "the failure names the endpoint"

finish
