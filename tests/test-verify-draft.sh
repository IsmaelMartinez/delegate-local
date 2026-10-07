#!/usr/bin/env bash
# Unit tests for scripts/verify-draft.sh (#659). A mock `curl` on a restricted
# PATH answers discovery and chat/completions; the probability it gives the
# first option letter is read from a SCORE_<p> marker in the request, so each
# case sets p(supported) from its own facts or draft.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
SCRIPT="$REPO/scripts/verify-draft.sh"

mock=$(mktemp -d)
sniff="$mock/payloads"
: > "$sniff"
data="$TEST_ROOT/data"
mkdir -p "$data/drafts"
write_mock() {
  cat > "$mock/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */models) printf '%s' '$(mock_models_json $MOCK_MODELS)' ;;
  */chat/completions)
    body=\$(cat)
    printf '%s\n' "\$body" >> "$sniff"
    s=\$(printf '%s' "\$body" | grep -o 'SCORE_[0-9.]*' | head -1)
    s=\${s#SCORE_}
    perl -e 'my \$p = shift || 0.5; my (\$a, \$b) = (log(\$p), log(1 - \$p));
      printf q({"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":%.8f,"top_logprobs":[{"token":"A","logprob":%.8f},{"token":"B","logprob":%.8f}]}]}}]}), \$a, \$a, \$b' "\$s" ;;
esac
EOF
  chmod +x "$mock/curl"
}
write_mock
cleanup_on_exit "$mock"

run() { PATH="$mock:$SAFE_PATH" DELEGATE_LOCAL_DATA_DIR="$data" bash "$SCRIPT" "$@"; }

echo "stdin mode"
out=$(run <<<'{"facts":"The fix landed in abc123.","draft":"Fixed in abc123. SCORE_0.9"}' 2>"$mock/err")
rc=$?
assert_eq "0" "$rc" "a supported draft exits 0"
assert_eq "pass" "$(jq -r '.verdict' <<<"$out")" "and is a pass"
assert_eq "0.9" "$(jq -r '.p_supported' <<<"$out")" "p_supported is the true probability"
assert_eq "qwen3.6:35b-a3b" "$(jq -r '.model' <<<"$out")" "model comes from the verify tier"
assert_eq "number" "$(jq -r '.latency_ms | type' <<<"$out")" "latency recorded"
assert_eq "0.5" "$(jq -r '.threshold' <<<"$out")" "uncalibrated falls back to 0.5"
assert_contains "no calibrated threshold for qwen3.6:35b-a3b" "$(cat "$mock/err")" "and says so on stderr"
prompt=$(tail -1 "$sniff" | jq -r '.messages[0].content')
assert_contains 'Is every claim in `draft` stated in or directly implied by `facts`?' "$prompt" "the measured question is asked"
assert_contains 'nothing is reversed, swapped or added' "$prompt" "with the measured criteria"
assert_contains '"facts":"The fix landed in abc123."' "$prompt" "facts go in the state"

out=$(run <<<'{"facts":"The fix landed in abc123.","draft":"Reverted abc123. SCORE_0.2"}' 2>/dev/null)
rc=$?
assert_eq "1" "$rc" "an unsupported draft exits 1"
assert_eq "flag" "$(jq -r '.verdict' <<<"$out")" "and is a flag"

: > "$sniff"
long=$(head -c 20000 /dev/zero | tr '\0' 'x')
run >/dev/null 2>&1 <<<"$(jq -nc --arg f "$long" '{facts:$f, draft:"SCORE_0.9"}')"
facts_sent=$(tail -1 "$sniff" | jq -r '.messages[0].content' | grep -o 'x*' | awk '{ if (length > m) m = length } END { print m }')
assert_eq "16000" "$facts_sent" "facts are cut at 16000 characters, as measured"

echo "threshold"
printf 'other-model\t0.1\nqwen3.6:35b-a3b\t0.95\n' > "$data/verify-thresholds.tsv"
out=$(run <<<'{"facts":"f","draft":"SCORE_0.9"}' 2>"$mock/err")
rc=$?
assert_eq "1" "$rc" "a calibrated threshold above p flags"
assert_eq "0.95" "$(jq -r '.threshold' <<<"$out")" "the resolved model's line is used"
assert_not_contains "no calibrated threshold" "$(cat "$mock/err")" "no uncalibrated note once calibrated"
out=$(DELEGATE_VERIFY_THRESHOLD=0.85 run <<<'{"facts":"f","draft":"SCORE_0.9"}' 2>/dev/null)
rc=$?
assert_eq "0" "$rc" "DELEGATE_VERIFY_THRESHOLD overrides the file"
assert_eq "0.85" "$(jq -r '.threshold' <<<"$out")" "and is reported"
DELEGATE_VERIFY_THRESHOLD=high run <<<'{"facts":"f","draft":"SCORE_0.9"}' >/dev/null 2>&1
assert_eq "2" "$?" "a non-numeric DELEGATE_VERIFY_THRESHOLD exits 2"
rm -f "$data/verify-thresholds.tsv"

echo "id mode"
printf '%s\n' '{"stdin":"SCORE_0.9 piped context","vars":{"zeta":"last var","alpha":"first var"},"prompt":"not a fact"}' > "$data/drafts/20261007T000000Z-feedc0de.inputs.json"
printf 'The drafted reply.' > "$data/drafts/20261007T000000Z-feedc0de.draft.txt"
{
  printf '%s\n' '{"ts":"2026-10-07T00:00:00Z","source":"delegate","otel_span_id":"feedc0de11112222","recipe":"pr-review-reply","draft_file":"20261007T000000Z-feedc0de.draft.txt","inputs_file":"20261007T000000Z-feedc0de.inputs.json"}'
  printf '%s\n' '{"ts":"2026-10-07T00:00:01Z","source":"delegate","otel_span_id":"0000aaaa1111bbbb","draft_file":"20261007T000001Z-0000aaaa.draft.txt"}'
} > "$data/metrics.jsonl"
: > "$sniff"
out=$(run --id feedc0de11112222 2>/dev/null)
rc=$?
assert_eq "0" "$rc" "id mode passes a supported draft"
prompt=$(tail -1 "$sniff" | jq -r '.messages[0].content')
assert_contains '"facts":"SCORE_0.9 piped context\nfirst var\nlast var"' "$prompt" "facts are stdin then the vars by key, newline-joined, without the prompt"
assert_contains '"draft":"The drafted reply."' "$prompt" "the stored draft is checked"
run --id 0000aaaa1111bbbb >/dev/null 2>"$mock/err"
assert_eq "2" "$?" "a row with no stored inputs exits 2"
assert_contains "no stored inputs" "$(cat "$mock/err")" "and says why"
run --id nosuchid >/dev/null 2>&1
assert_eq "2" "$?" "an unknown id exits 2"

echo "usage"
run --bogus </dev/null >/dev/null 2>&1
assert_eq "2" "$?" "an unknown argument exits 2"
run <<<'{"facts":"f"}' >/dev/null 2>&1
assert_eq "2" "$?" "stdin without a draft exits 2"
run --id >/dev/null 2>&1
assert_eq "2" "$?" "a value-less --id exits 2"
assert_contains "Exit codes" "$(run --help)" "--help documents the exit codes"

echo "verifier unavailable"
MOCK_MODELS='unrelated:model'
write_mock
run <<<'{"facts":"f","draft":"SCORE_0.9"}' >/dev/null 2>&1
assert_eq "3" "$?" "no model for the verify tier exits 3"
MOCK_MODELS='qwen3.6:35b-a3b'
write_mock

echo "calibrate"
set_file="$TEST_ROOT/set.jsonl"
# supported 0.9 0.8 0.4, not supported 0.6 0.3 0.2: 8 of 9 pairs ordered, so
# AUROC 0.889; thresholds 0.8 and 0.4 tie at balanced accuracy 0.833 and the
# higher one wins.
for r in supported:0.9 supported:0.8 supported:0.4 contradicted:0.6 contradicted:0.3 unsupported:0.2; do
  jq -nc --arg l "${r%%:*}" --arg p "${r#*:}" '{facts:"f", draft:("SCORE_" + $p), label:$l}'
done > "$set_file"
out=$(run --calibrate "$set_file" --dry-run 2>&1)
rc=$?
assert_eq "0" "$rc" "--calibrate exits 0"
assert_contains "n=6" "$out" "reports n"
assert_contains "auroc=0.889" "$out" "AUROC over the not-supported labels"
assert_contains "threshold=0.8 " "$out" "the higher of two tied thresholds"
assert_contains "accuracy=5/6" "$out" "accuracy at the chosen threshold"
assert_contains "acc@0.5=4/6" "$out" "and at 0.5 for comparison"
assert_contains "supported=2/3 contradicted=2/2 unsupported=1/1" "$out" "recall per label"
assert_contains "p50_ms=" "$out" "p50 latency"
assert_true "--dry-run records nothing" test ! -e "$data/verify-thresholds.tsv"
run --calibrate "$set_file" >/dev/null 2>&1
run --calibrate "$set_file" >/dev/null 2>&1
assert_eq "$(printf 'qwen3.6:35b-a3b\t0.8')" "$(cat "$data/verify-thresholds.tsv")" "--calibrate records one line per model, replacing the last"
out=$(run <<<'{"facts":"f","draft":"SCORE_0.7"}' 2>/dev/null)
assert_eq "flag" "$(jq -r '.verdict' <<<"$out")" "the recorded threshold is then used"
head -3 "$set_file" > "$TEST_ROOT/one-class.jsonl"
run --calibrate "$TEST_ROOT/one-class.jsonl" >/dev/null 2>&1
assert_eq "2" "$?" "a set without both classes exits 2"
run --calibrate "$TEST_ROOT/missing.jsonl" >/dev/null 2>&1
assert_eq "2" "$?" "a missing set exits 2"

finish
