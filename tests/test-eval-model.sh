#!/usr/bin/env bash
# Unit tests for scripts/eval-model.sh (#678, ADR 0034). The three step
# scripts (replay-recipe.sh, verify-draft.sh, eval-skill-triggers.sh) are stubs
# injected through DELEGATE_EVAL_SCRIPTS, each answering from env so every
# verdict path can be set up; pick-model.sh is the real one, resolving the
# champion through a mock curl. The mock serves the champion at champ.test,
# listing the fixture prose model, the candidate at cand.test, the champion
# again at localhost:8080, and both at both.test. Each call takes a simulated
# MC_SLEEP_CAND or MC_SLEEP_CHAMP on the virtual clock (DELEGATE_EVAL_CLOCK),
# so the cost ratio is set by the test; on the real clock it sleeps and holds
# a busy file, which the ioreg stub reads as 90% (10% otherwise) when MC_UTIL
# is set.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
SCRIPT="$REPO/scripts/eval-model.sh"
CAND="cand-model"

mock="$TEST_ROOT/mock"
stubs="$TEST_ROOT/stubs"
data="$TEST_ROOT/data"
mkdir -p "$mock" "$stubs" "$data/drafts"

cat > "$mock/curl" <<EOF
#!/usr/bin/env bash
url=""; body=""
while (( \$# > 0 )); do
  case "\$1" in
    http*) url="\$1"; shift ;;
    -d) body="\$2"; shift 2 ;;
    --data-binary) shift 2 ;;
    -m|--max-time|--connect-timeout|-H|-X|-o|-w) shift 2 ;;
    *) shift ;;
  esac
done
case "\$url" in
  http://champ.test/v1/models) printf '%s' '$(mock_models_json "$PROSE_MODEL")'; exit 0 ;;
  http://cand.test/v1/models) printf '%s' '$(mock_models_json "$CAND" other-model)'; exit 0 ;;
  http://localhost:8080/v1/models) printf '%s' '$(mock_models_json "$PROSE_MODEL")'; exit 0 ;;
  http://both.test/v1/models) printf '%s' '$(mock_models_json "$PROSE_MODEL" "$CAND")'; exit 0 ;;
  */models) exit 7 ;;
esac
[[ -n "\$body" ]] || body=\$(cat)
m=\$(printf '%s' "\$body" | jq -r '.model')
printf '%s %s %s\n' "\$url" "\$m" "\$(printf '%s' "\$body" | jq -c '[.temperature, .chat_template_kwargs.enable_thinking, .max_tokens]')" >> "$mock/log"
# HTTP errors, as curl --fail reports them: the candidate on the prompt that
# carries MC_FAIL_MARK, or on its one-token first call with MC_FAIL_FIRST.
if [[ "\$m" == "${CAND}" ]]; then
  [[ -n "\${MC_FAIL_MARK:-}" && "\$body" == *"\$MC_FAIL_MARK"* ]] && exit 22
  [[ -n "\${MC_FAIL_FIRST:-}" && "\$(printf '%s' "\$body" | jq -r '.max_tokens')" == 1 ]] && exit 22
fi
[[ "\$m" == "${CAND}" ]] && s="\${MC_SLEEP_CAND:-0.1}" || s="\${MC_SLEEP_CHAMP:-0.1}"
# MC_SLOW_MARK: the prompt carrying it takes MC_SLOW on either arm.
[[ -n "\${MC_SLOW_MARK:-}" && "\$body" == *"\$MC_SLOW_MARK"* ]] && s="\$MC_SLOW"
# With the harness on the virtual clock the call takes exactly s; on the real
# one (the GPU test) it sleeps, holding the busy file the ioreg stub reads.
if [[ -n "\${DELEGATE_EVAL_CLOCK:-}" ]]; then
  awk -v s="\$s" '{ printf "%.3f", \$1 + s }' "\$DELEGATE_EVAL_CLOCK" > "\$DELEGATE_EVAL_CLOCK.new" && mv "\$DELEGATE_EVAL_CLOCK.new" "\$DELEGATE_EVAL_CLOCK"
else
  touch "$mock/busy"; sleep "\$s"; rm -f "$mock/busy"
fi
# MC_HOT: the first full-length call heats the machine to serious (2), which
# the osascript stub then reports; MC_HOT_FIRST: the candidate's one-token
# first call (a cold load) does.
if [[ -n "\${MC_HOT:-}" ]] && [[ "\$(printf '%s' "\$body" | jq -r '.max_tokens')" == 4096 ]]; then
  echo 2 > "$mock/thermal"
fi
if [[ -n "\${MC_HOT_FIRST:-}" && "\$m" == "${CAND}" ]] && [[ "\$(printf '%s' "\$body" | jq -r '.max_tokens')" == 1 ]]; then
  echo 2 > "$mock/thermal"
fi
# MC_THINK: the candidate answers with a reasoning trace in the server's
# reasoning field, running to max_tokens, as a model that ignores
# enable_thinking does.
if [[ "\$m" == "${CAND}" && -n "\${MC_THINK:-}" ]]; then
  printf '{"choices":[{"message":{"content":"ok","reasoning":"We need to..."},"finish_reason":"length"}],"usage":{"prompt_tokens":100,"completion_tokens":4096}}'
elif [[ "\$m" == "${CAND}" && -n "\${MC_EMPTY:-}" ]]; then
  printf '{"choices":[{"message":{"content":null,"reasoning":"We need to..."},"finish_reason":"length"}],"usage":{"prompt_tokens":100,"completion_tokens":4096}}'
else
  printf '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50}}'
fi
EOF
cat > "$mock/ioreg" <<EOF
#!/usr/bin/env bash
[[ -n "\${MC_UTIL:-}" ]] || exit 0
[[ -f "$mock/busy" ]] && u=90 || u=10
printf '| "PerformanceStatistics" = {"Device Utilization %%"=%s}\n' "\$u"
EOF
printf '#!/usr/bin/env bash\ncat "%s/thermal" 2>/dev/null || echo 0\n' "$mock" > "$mock/osascript"
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock/caffeinate"
chmod +x "$mock"/*

# Stubs: each logs its argv, its pinned model and its cwd, then answers.
cat > "$stubs/replay-recipe.sh" <<'EOF'
#!/usr/bin/env bash
echo "replay $*" >> "$STUB_LOG"
r=""; while (( $# > 0 )); do [[ "$1" == --recipe ]] && r="$2"; shift; done
v=$(printf '%s' "${STUB_REPLAY:-}" | tr ',' '\n' | sed -n "s/^$r=//p")
# CHECKSUP wins on anchors while its failed checks rise, which the real
# replay reports as INCONCLUSIVE; ERRS has one case that failed to run.
e=0; hc=0; cc=0
case "${v:-INCONCLUSIVE}" in
  NONE) echo "replay-recipe: no replayable edited case" >&2; exit 3 ;;
  HOT) exit 75 ;;
  BROKEN) echo "replay-recipe: boom" >&2; exit 2 ;;
  ACCEPT) w=6; l=0; p="Sign test: p=0.016 (one-sided, 6 wins to 0)" ;;
  REJECT) w=0; l=6; p="Sign test: p=0.016 (one-sided, 6 losses to 0)" ;;
  CHECKSUP) w=6; l=0; hc=1; cc=5; p="Sign test: p=0.016 (one-sided, 6 wins to 0)"; v=INCONCLUSIVE ;;
  ERRS) w=2; l=1; e=1; p="Sign test: p=0.500 (one-sided, 2 wins to 1)"; v=INCONCLUSIVE ;;
  *) w=2; l=2; p="" ;;
esac
echo "=== replay: $r (model comparison) ==="
printf '  %-10s %-20s %-8s %-18s %-18s %s\n' rej0000001 2026-09-01T10:00:00Z rewrote 0/2/1/0/0/0/0=3 0/1/0/1/0/0/0=2 WIN
printf '  %-10s %-20s %-8s %-18s %-18s %s\n' rej0000002 2026-09-02T10:00:00Z scaffold 1/0/3/0/0/0/0=4 0/0/2/2/0/0/0=4 tie
echo "Summary: n=$((w + l + e))  wins=$w  losses=$l  ties=0  errors=$e"
echo "Checks failed: champion=$hc  candidate=$cc"
echo "Length flags: champion=0  candidate=0"
[[ -n "$p" ]] && echo "$p"
echo "Verdict: ${v:-INCONCLUSIVE} — stub."
EOF
cat > "$stubs/verify-draft.sh" <<'EOF'
#!/usr/bin/env bash
echo "verify $DELEGATE_MODEL $DELEGATE_BASE_URL $*" >> "$STUB_LOG"
[[ -n "${STUB_VERIFY_FAIL:-}" ]] && { echo "verify-draft: the verifier is unavailable" >&2; exit 3; }
# STUB_OFF_FORMAT: no row scores on the candidate; STUB_OFF_ROWS=N: N rows
# open with neither letter and the rest score, which verify-draft.sh reports
# with errors=N and exit 3.
if [[ -n "${STUB_OFF_FORMAT:-}" && "$DELEGATE_MODEL" == cand-model ]]; then
  echo "verify-draft: the verifier answered with neither option letter (coverage 0); no score" >&2
  echo "verify-draft: no row could be scored" >&2; exit 3
fi
if [[ "$DELEGATE_MODEL" == cand-model ]]; then a="${STUB_AUROC_CAND:-0.900}"; t="${STUB_THRESHOLD_CAND:-0.81}"; else a="${STUB_AUROC_CHAMP:-0.900}"; t=0.77; fi
bad=0
if [[ -n "${STUB_OFF_ROWS:-}" && "$DELEGATE_MODEL" == cand-model ]]; then
  bad="$STUB_OFF_ROWS"
  for _ in $(seq 1 "$bad"); do echo "verify-draft: the verifier answered with neither option letter (coverage 0); no score" >&2; done
fi
echo "verify-calibrate: model=$DELEGATE_MODEL errors=$bad n=120 auroc=$a threshold=$t balanced_accuracy=0.880 accuracy=100/120 acc@0.5=90/120 recall supported=50/60 contradicted=28/30 unsupported=27/30 p50_ms=300"
if (( bad > 0 )); then echo "verify-calibrate: $bad row(s) could not be scored; threshold not recorded" >&2; exit 3; fi
EOF
cat > "$stubs/eval-skill-triggers.sh" <<'EOF'
#!/usr/bin/env bash
echo "trigger $DELEGATE_MODEL $DELEGATE_BASE_URL $(pwd) $*" >> "$STUB_LOG"
echo "scoring: backend=decide model=logprob"
if [[ -n "${STUB_OFF_FORMAT:-}" && "$DELEGATE_MODEL" == cand-model ]]; then
  echo "FAIL: the answer letters held only 0 of the model's mass on p01; no score" >&2; exit 2
fi
echo "scored on: $DELEGATE_MODEL"
if [[ "$DELEGATE_MODEL" == cand-model && -n "${STUB_TRIGGER_FAIL:-}" ]]; then
  echo "results: tp=17 fn=5 tn=15 fp=0 recall=0.773 negative-precision=1.000"; exit 1
fi
echo "results: tp=21 fn=1 tn=15 fp=0 recall=0.955 negative-precision=1.000"
EOF
chmod +x "$stubs"/*

# A corpus: rp1 has three delegations, rp2 two and rp3 one, each with a
# rendered input the cost step can send.
: > "$data/metrics.jsonl"
i=0
for r in rp1 rp1 rp1 rp2 rp2 rp3; do
  i=$((i + 1))
  stem=$(printf '20261001T10%02d00Z-case%04d' "$i" "$i")
  printf 'Rendered prompt %s for %s.\n' "$i" "$r" > "$data/drafts/$stem.input.txt"
  printf '{"ts":"2026-10-01T10:%02d:00Z","source":"delegate","recipe":"%s","model":"%s","exit_status":0,"input_file":"%s.input.txt"}\n' \
    "$i" "$r" "$PROSE_MODEL" "$stem" >> "$data/metrics.jsonl"
done
printf '{"ts":"2026-10-01T11:00:00Z","source":"feedback","ref_id":"x","kept":true}\n' >> "$data/metrics.jsonl"
mkdir -p "$data/spikes/clef/grounding"
printf '{"facts":"f","draft":"d","label":"supported"}\n' > "$data/spikes/clef/grounding/ground.jsonl"

# Every run reads the virtual clock unless a test sets DELEGATE_EVAL_CLOCK=
# for the real one, and finds the champion at champ.test unless MC_CHAMP_BASE
# names another provider.
run() {
  PATH="$mock:$SAFE_PATH" DELEGATE_LOCAL_DATA_DIR="$data" DELEGATE_BASE_URL="${MC_CHAMP_BASE:-http://champ.test/v1}" \
    DELEGATE_EVAL_SCRIPTS="$stubs" DELEGATE_GPU_GATE="${DELEGATE_GPU_GATE:-0}" STUB_LOG="$TEST_ROOT/stub.log" \
    DELEGATE_EVAL_CLOCK="${DELEGATE_EVAL_CLOCK-$TEST_ROOT/clock}" \
    bash "$SCRIPT" "$@"
}
fresh() { rm -rf "$data/evals"; : > "$TEST_ROOT/stub.log"; : > "$mock/log"; printf '1000.000' > "$TEST_ROOT/clock"; echo 0 > "$mock/thermal"; }
printf '1000.000' > "$TEST_ROOT/clock"
card() { jq -r "$1" "$(ls -d "$data"/evals/2*/ | tail -n 1)card.json"; }

echo "== usage and preflight =="
EC=0; out=$(run 2>&1) || EC=$?
assert_eq 2 "$EC" "no --model exits 2"
assert_contains "--model is required" "$out" "and says so"
EC=0; out=$(run --model "$CAND" --skip judge 2>&1) || EC=$?
assert_eq 2 "$EC" "an unknown --skip step exits 2"
EC=0; out=$(run --model "$CAND" --base http://user:secret@cand.test/v1 2>&1) || EC=$?
assert_eq 2 "$EC" "userinfo in --base exits 2"
assert_not_contains "secret" "$out" "and is never printed"
EC=0; out=$(run --model "$PROSE_MODEL" --base http://cand.test/v1 2>&1) || EC=$?
assert_eq 2 "$EC" "the champion as candidate exits 2"
assert_contains "nothing to compare" "$out" "and says why"
EC=0; out=$(run --model "$CAND" --base http://champ.test/v1/ 2>&1) || EC=$?
assert_eq 2 "$EC" "the champion's own server as --base exits 2"
assert_contains "swaps models rather than stacking them" "$out" "the swap is named"
assert_contains "mlx_lm.server --model $CAND --port 8081" "$out" "with the command that avoids it"
EC=0; out=$(run --model "$CAND" --base http://champ.test/v1 --same-server 2>&1) || EC=$?
assert_eq 3 "$EC" "--same-server lifts the refusal (and the champion's server does not list the candidate)"
# localhost, 127.0.0.1 and [::1] name one server.
EC=0; out=$(MC_CHAMP_BASE=http://localhost:8080/v1 run --model "$CAND" --base http://127.0.0.1:8080/v1 2>&1) || EC=$?
assert_eq 2 "$EC" "127.0.0.1 is refused when the champion is on localhost"
assert_contains "swaps models rather than stacking them" "$out" "with the swap named"
EC=0; out=$(MC_CHAMP_BASE=http://localhost:8080/v1 run --model "$CAND" --base 'http://[::1]:8080/v1' 2>&1) || EC=$?
assert_eq 2 "$EC" "and so is [::1]"
# A named grounding set that is not there is an error, not a silent skip.
EC=0; out=$(run --model "$CAND" --base http://cand.test/v1 --grounding "$data/typo.jsonl" 2>&1) || EC=$?
assert_eq 2 "$EC" "a --grounding file that does not exist exits 2"
assert_contains "--grounding $data/typo.jsonl not found" "$out" "and names it"
# A leading zero is base 10, not octal.
EC=0; err=$(run --model "$CAND" --base http://cand.test/v1 --prompts 08 --skip replay,grounding,trigger 2>&1 >/dev/null) || EC=$?
assert_eq 0 "$EC" "--prompts 08 runs"
assert_not_contains "value too great" "$err" "and is not read as octal"
rm -rf "$data/evals"
EC=0; out=$(run --model "$CAND" --base http://nowhere.test/v1 2>&1) || EC=$?
assert_eq 3 "$EC" "a base that does not list the candidate exits 3"
assert_contains "does not list $CAND" "$out" "and names it"
EC=0; out=$(run --model other --base http://cand.test/v1 2>&1) || EC=$?
assert_eq 3 "$EC" "an id the base lists only as a substring is not served"
assert_eq "" "$(ls "$data/evals" 2>/dev/null)" "a refused run writes nothing"

echo "== a full card =="
fresh
rows_before=$(grep -c '' "$data/metrics.jsonl")
# Equal simulated durations on both arms put the cost ratio at exactly 1
# wherever cost is not what a test is about.
EC=0; out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_REPLAY="rp1=ACCEPT,rp2=INCONCLUSIVE,rp3=NONE" \
  run --model "$CAND" --base http://cand.test/v1 --prompts 4 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "a run exits 0"
assert_eq "Verdict: TRIAL — better on rp1: replay ACCEPT, 6 wins to 0 (p=0.016); worth a live trial (docs/model-swap.md step 7) after the blind judge (step 3)." \
  "$(printf '%s\n' "$out" | tail -n 1)" "the last line is the verdict, with its reason"
assert_contains "=== eval-model: $CAND against the prose tier's $PROSE_MODEL ===" "$out" "the header names both models"
assert_contains "Candidate: $CAND at http://cand.test/v1" "$out" "and the candidate's base"
assert_contains "Champion:  $PROSE_MODEL at http://champ.test/v1" "$out" "and the champion's"
# The cost step: every prompt to both servers by exact id, as delegate.sh asks.
assert_eq 5 "$(grep -c "^http://cand.test/v1/chat/completions $CAND " "$mock/log")" "four prompts and one first call go to the candidate"
assert_eq 5 "$(grep -c "^http://champ.test/v1/chat/completions $PROSE_MODEL " "$mock/log")" "and the same to the champion, by its exact id"
assert_eq 8 "$(grep -c ' \[0,false,4096\]$' "$mock/log")" "each prompt is greedy, thinking off, delegate.sh's max_tokens"
assert_eq "candidate champion champion candidate" "$(grep -v '^$' "$data"/evals/2*/cost.tsv | head -n 4 | cut -f1 | tr '\n' ' ' | sed 's/ $//')" \
  "the arms alternate which goes first"
assert_contains "Cost, 4 stored prompts sent to both, 4 answered by both" "$out" "cost is reported over the prompts both answered"
assert_contains "ratio                    1.00 (seconds per call)" "$out" "with the ratio"
assert_eq "$rows_before" "$(grep -c '' "$data/metrics.jsonl")" "no metrics row is written"
# The replay: each of the busiest recipes, edited cases only, candidate pinned.
assert_eq 3 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "the replay runs the recipes in the metrics"
assert_contains "replay --recipe rp1 --candidate-model $CAND --candidate-base http://cand.test/v1 --edited-only --limit 20" \
  "$(cat "$TEST_ROOT/stub.log")" "on the edited cases, the candidate pinned to its base"
# Anchors are summed over the listed cases: champion 0/2/1 + 1/0/3 fields
# 2-4 give 2/4/0, candidate 1/0/1 + 0/2/2 give 1/2/3.
assert_eq " rp1 n=6 W6 L0 T0 p=0.016 ACCEPT 2/4/0 | 1/2/3 checks 0|0 length 0|0" "$(printf '%s\n' "$out" | grep -E '^  rp1 ' | sed -E 's/ +/ /g')" \
  "a recipe line carries the tally, p, verdict, dropped/over/invented, checks and length per arm"
assert_eq " rp3 no edited case" "$(printf '%s\n' "$out" | grep -E '^  rp3 ' | sed -E 's/ +/ /g')" "a recipe without an edited case says so"
# Grounding and trigger on both models, each pinned by exact id to its base.
assert_contains "verify $CAND http://cand.test/v1 --calibrate $data/spikes/clef/grounding/ground.jsonl --dry-run" "$(cat "$TEST_ROOT/stub.log")" "grounding runs on the candidate, dry"
assert_contains "verify $PROSE_MODEL http://champ.test/v1 --calibrate" "$(cat "$TEST_ROOT/stub.log")" "and on the champion"
assert_contains "trigger $CAND http://cand.test/v1 $REPO --decide" "$(cat "$TEST_ROOT/stub.log")" "the trigger gate runs from the repo root on the candidate"
assert_contains "  candidate auroc=0.900 threshold=0.81 balanced_accuracy=0.880 n=120" "$out" "grounding is reported per arm"
assert_contains "  candidate recall=0.955 negative-precision=1.000 pass" "$out" "and the trigger gate"
assert_contains "blind judge" "$out" "the manual step is named"
assert_eq "TRIAL" "$(card .verdict)" "the card carries the verdict"
assert_eq "6 0" "$(card '.replay[] | select(.recipe == "rp1") | "\(.wins) \(.losses)"')" "and the replay rows"
assert_eq "3" "$(card '.replay[] | select(.recipe == "rp1") | .candidate.invented')" "with the anchors per arm"
assert_eq "0 0" "$(card '.replay[] | select(.recipe == "rp1") | "\(.champion.checks) \(.candidate.checks)"')" "and the failed checks"
assert_eq "4 0" "$(card '"\(.cost.prompts_both_answered) \(.cost.candidate_failed_calls)"')" "and the cost counts"
assert_eq "none" "$(card '.replay[] | select(.recipe == "rp3") | .verdict')" "and the recipe with no case"
assert_eq "true" "$(card '.grounding.candidate_auroc == 0.9')" "and grounding, as a number"
assert_eq "$CAND" "$(card .candidate.model)" "and the models"

echo "== the per-model cache =="
: > "$TEST_ROOT/stub.log"
STUB_REPLAY="rp1=ACCEPT" run --model "$CAND" --base http://cand.test/v1 --skip cost >/dev/null 2>&1
assert_eq 0 "$(grep -c '^verify ' "$TEST_ROOT/stub.log")" "a second run reads grounding from the cache"
assert_eq 0 "$(grep -c '^trigger ' "$TEST_ROOT/stub.log")" "and the trigger gate"
assert_eq 3 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "the replay runs again (it keeps its own cache)"

echo "== stop =="
fresh
out=$(STUB_REPLAY="rp1=REJECT" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "Verdict: STOP — replay: rp1 REJECT, 6 losses to 0 wins (p=0.016)" "$out" "a replay REJECT stops"
fresh
out=$(STUB_REPLAY="rp1=ACCEPT" STUB_TRIGGER_FAIL=1 run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "Verdict: STOP — trigger gate: recall 0.773, negative precision 1.000 under the bar" "$out" "a failed trigger gate stops, whatever the replay"
assert_contains "  candidate recall=0.773 negative-precision=1.000 FAIL" "$out" "and is shown failing"
fresh
out=$(STUB_AUROC_CAND=0.840 run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "Verdict: STOP — grounding: AUROC 0.840 against the champion's 0.900" "$out" "grounding more than 0.05 under the champion's stops"
assert_eq 3 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "a judging failure still runs the replay, which shows the writer"
fresh
out=$(MC_SLEEP_CAND=0.4 MC_SLEEP_CHAMP=0.1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: STOP — cost: " "$out" "a candidate over 1.5 times the champion's time per call stops"
assert_contains "times the champion's seconds per call" "$out" "on wall seconds when ioreg reads nothing"
assert_not_contains "reasoned before answering" "$out" "a model that does not think is not said to"
assert_eq 0 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "the replay, the long step, is not run once cost stops the writer"
assert_contains "not run: the cost step already stops the candidate as a writer" "$out" "and the report says why"
# A reasoning model that ignores enable_thinking: the trace and the capped
# calls are counted and named in the reason, and a model that opens every
# lettered question with anything but a letter stops on both judging steps.
fresh
out=$(MC_THINK=1 MC_SLEEP_CAND=0.4 MC_SLEEP_CHAMP=0.1 STUB_OFF_FORMAT=1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "  output tokens per call   4096 / 50" "$out" "output tokens per call are reported"
assert_contains "  ran to max_tokens        2 of 2 / 0 of 2" "$out" "and the calls that ran to max_tokens"
assert_contains "  reasoning trace          2 of 2 / 0 of 2 (thinking requested off)" "$out" "and the calls that carried a reasoning trace"
assert_contains "and it reasoned before answering on 2 of 2 calls although thinking was off" "$out" "the cost reason names the thinking"
assert_contains "grounding: the candidate opened the verifier's lettered question with neither letter on 1 of 1 rows" "$out" "an off-format verifier stops"
assert_contains "trigger gate: it cannot score on the candidate" "$out" "and so does an off-format trigger gate"
assert_contains "  candidate no score: verify-draft: no row could be scored" "$out" "the last error line is shown"
# A verifier that misses the letters on a minority of rows holds the verdict
# open rather than stopping it; on half or more it stops.
printf '{"facts":"f","draft":"d","label":"supported"}\n%.0s' 1 2 3 4 > "$data/four.jsonl"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_OFF_ROWS=1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --grounding "$data/four.jsonl" 2>/dev/null)
assert_contains "Verdict: INCONCLUSIVE — grounding: 1 of 4 rows could not be scored (the answer opened with neither letter)" "$out" \
  "one off-format row in four holds the verdict open"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_OFF_ROWS=2 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --grounding "$data/four.jsonl" 2>/dev/null)
assert_contains "grounding: the candidate opened the verifier's lettered question with neither letter on 2 of 4 rows" "$out" "two in four stop it"
# A call that spent its budget thinking and came back empty cost the GPU and
# failed its delegation: it counts in the cost and stops the card.
fresh
out=$(MC_EMPTY=1 MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "  empty answer             2 of 2 / 0 of 2" "$out" "an empty answer is counted, not dropped as an error"
assert_contains "failed calls: the candidate failed 2 of 2 (transport errors 0, empty answers 2) against the champion's 0, each a failed delegation" "$out" \
  "and stops the card"
# A transport error is a failed delegation too, and the cost compares only the
# prompts both models answered: here the candidate fails the slow prompt, and
# averaged apart its time would look half the champion's.
fresh
out=$(MC_FAIL_MARK="Rendered prompt 6" MC_SLOW_MARK="Rendered prompt 6" MC_SLOW=3.0 MC_SLEEP_CAND=1.0 MC_SLEEP_CHAMP=1.0 \
  run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Cost, 2 stored prompts sent to both, 1 answered by both" "$out" "a prompt the candidate failed is left out of the comparison"
assert_contains "  transport errors         1 of 2 / 0 of 2" "$out" "and counted"
assert_contains "ratio                    1.00 (seconds per call)" "$out" "so the ratio is over the prompt both answered"
assert_contains "failed calls: the candidate failed 1 of 2 (transport errors 1, empty answers 0) against the champion's 0" "$out" "and the failure stops the card"

# The bars read the unrounded ratio: 1.503 prints as 1.50 and still stops,
# 0.903 prints as 0.90 and is not cheaper.
fresh
out=$(MC_SLEEP_CAND=1.503 MC_SLEEP_CHAMP=1.0 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: STOP — cost: 1.50 times the champion's seconds per call" "$out" "a ratio of 1.503 stops though it prints as 1.50"
fresh
out=$(MC_SLEEP_CAND=0.903 MC_SLEEP_CHAMP=1.0 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "ratio                    0.90 (seconds per call)" "$out" "a ratio of 0.903 prints as 0.90"
assert_contains "Verdict: HOLD" "$out" "and is not cheaper"
assert_eq "true" "$(card '.cost.ratio > 0.9 and .cost.ratio < 0.91')" "the card keeps the unrounded ratio"

echo "== go, hold and inconclusive =="
fresh
out=$(MC_SLEEP_CAND=0.1 MC_SLEEP_CHAMP=0.4 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: TRIAL — cheaper: " "$out" "a cheaper candidate with no stop is worth a trial"
fresh
out=$(STUB_AUROC_CAND=0.960 run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "Verdict: INCONCLUSIVE — cost skipped" "$out" "a skipped step that could stop it holds the verdict open"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_AUROC_CAND=0.960 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: TRIAL — better grounding: AUROC 0.960 against 0.900" "$out" "grounding 0.05 over the champion's is a reason to trial"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_AUROC_CAND=0.950 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: TRIAL — better grounding: AUROC 0.950 against 0.900" "$out" "exactly 0.050 over is better (0.9 + 0.05 is not 0.95 in floating point)"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: HOLD — it matches the champion without being cheaper or better" "$out" "a tie on every step is a hold"
# The replay's own rule carries to the card: cheaper, but with failed checks
# rising across the replay, is a hold, not a trial.
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=1.0 STUB_REPLAY="rp1=CHECKSUP" run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: HOLD — cheaper: 0.50 times the champion's seconds per call, but failed checks rose from 1 to 5 across the replay" "$out" \
  "a rise in failed checks holds back a cheaper candidate"
assert_contains "checks 1|5" "$out" "and the recipe line shows it"
fresh
out=$(STUB_REPLAY="rp1=ERRS" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "replay: 1 case(s) of rp1 failed to run" "$out" "a replay case that did not run holds the verdict open"
fresh
out=$(MC_FAIL_FIRST=1 MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --skip replay 2>/dev/null)
assert_contains "  candidate first call     failed (includes any lazy load)" "$out" "a failed first call reads as failed"
# --same-server lets one provider serve both models, each still asked for by
# its exact id.
fresh
EC=0; out=$(MC_CHAMP_BASE=http://both.test/v1 MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 \
  run --model "$CAND" --base http://both.test/v1 --same-server --prompts 2 --skip replay,grounding,trigger 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "--same-server runs on a provider that holds both"
assert_eq "3 3" "$(grep -c "^http://both.test/v1/chat/completions $CAND " "$mock/log") $(grep -c "^http://both.test/v1/chat/completions $PROSE_MODEL " "$mock/log")" \
  "each model asked for by its exact id"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_VERIFY_FAIL=1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: INCONCLUSIVE — grounding: the verifier question could not be scored on the candidate" "$out" "a verifier that cannot score holds the verdict open"
assert_eq "" "$(find "$data/evals/cache" -name '*.grounding.*')" "and a failed score is not cached"
fresh
out=$(STUB_REPLAY="rp1=BROKEN" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "replay: rp1 did not run (exit 2)" "$out" "a replay that fails holds the verdict open"
# The default grounding set missing (another machine) is reported, not gating.
fresh
mv "$data/spikes/clef/grounding/ground.jsonl" "$data/ground.jsonl.away"
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
mv "$data/ground.jsonl.away" "$data/spikes/clef/grounding/ground.jsonl"
assert_contains "not measured: no labelled set at $data/spikes/clef/grounding/ground.jsonl" "$out" "no default grounding set is reported"
assert_contains "Verdict: HOLD" "$out" "and does not hold the verdict open"
fresh
out=$(STUB_THRESHOLD_CAND=0.9999 run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "scores pile up near 1" "$out" "a saturated verifier threshold is called out"

echo "== the heat gate and the GPU measure =="
fresh
EC=0; out=$(STUB_REPLAY="rp1=HOT" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>&1) || EC=$?
assert_eq 75 "$EC" "a replay stopped by the heat gate stops the run with 75"
assert_contains "rerun to resume" "$out" "and says how to resume"
# The gate runs before every cost call, not once per prompt: the candidate's
# first full call heats the machine, and the champion's is never sent.
fresh
EC=0; out=$(MC_HOT=1 DELEGATE_GPU_GATE=1 DELEGATE_GPU_WAIT_MAX=0 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>&1) || EC=$?
assert_eq 75 "$EC" "a machine the first arm heats stops the run with 75"
assert_eq "1 0" "$(grep -c "cand.test.* \[0,false,4096\]$" "$mock/log") $(grep -c "champ.test.* \[0,false,4096\]$" "$mock/log")" \
  "before the second arm's call is sent"
# A candidate whose cold load heats the machine stops the run before the
# champion's warm-up.
fresh
EC=0; out=$(MC_HOT_FIRST=1 DELEGATE_GPU_GATE=1 DELEGATE_GPU_WAIT_MAX=0 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>&1) || EC=$?
assert_eq 75 "$EC" "a cold load that heats the machine stops the run with 75"
assert_eq 0 "$(grep -c '^http://champ.test' "$mock/log")" "before the champion's warm-up is sent"
fresh
# The one test on the real clock: ioreg is sampled in real time, twice a
# second, so each call lasts long enough to hold several samples.
out=$(DELEGATE_EVAL_CLOCK='' MC_UTIL=1 MC_SLEEP_CAND=2.4 MC_SLEEP_CHAMP=1.2 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --skip replay 2>/dev/null)
assert_contains "GPU busy-seconds/call" "$out" "with ioreg readable, GPU busy-seconds are reported"
assert_contains "(GPU busy-seconds per call)" "$out" "and are the cost measure"
assert_eq "true" "$(card '.cost.ratio > 1')" "the slower candidate costs more GPU time"

echo "== the recipes come from the metrics when not named =="
fresh
run --model "$CAND" --base http://cand.test/v1 --skip cost,grounding,trigger >/dev/null 2>&1
assert_eq "rp1 rp2 rp3" "$(sed -n 's/^replay --recipe \([^ ]*\) .*/\1/p' "$TEST_ROOT/stub.log" | tr '\n' ' ' | sed 's/ $//')" \
  "busiest first"
: > "$TEST_ROOT/stub.log"
run --model "$CAND" --base http://cand.test/v1 --skip cost,grounding,trigger --recipes rp2 >/dev/null 2>&1
assert_eq "rp2" "$(sed -n 's/^replay --recipe \([^ ]*\) .*/\1/p' "$TEST_ROOT/stub.log")" "--recipes names them"

echo "== --skip takes a list however it is spaced =="
fresh
out=$(run --model "$CAND" --base http://cand.test/v1 --skip 'cost, replay' 2>/dev/null)
assert_eq 0 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "'cost, replay' skips the replay"
assert_contains "Verdict: INCONCLUSIVE — cost skipped; replay skipped" "$out" "and the cost step, as validated"

finish
