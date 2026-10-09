#!/usr/bin/env bash
# Unit tests for scripts/eval-model.sh (#678, ADR 0034). The three step
# scripts (replay-recipe.sh, verify-draft.sh, eval-skill-triggers.sh) are stubs
# injected through DELEGATE_EVAL_SCRIPTS, each answering from env so every
# verdict path can be set up; pick-model.sh is the real one, resolving the
# champion through a mock curl. The mock serves two providers: the champion at
# champ.test, listing the fixture prose model, and the candidate at cand.test.
# It sleeps per model (MC_SLEEP_CAND, MC_SLEEP_CHAMP), so the cost ratio is
# set by the test, and holds a busy file while it "generates", which the
# ioreg stub reads as 90% (10% otherwise) when MC_UTIL is set.

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
  */models) exit 7 ;;
esac
[[ -n "\$body" ]] || body=\$(cat)
m=\$(printf '%s' "\$body" | jq -r '.model')
printf '%s %s %s\n' "\$url" "\$m" "\$(printf '%s' "\$body" | jq -c '[.temperature, .chat_template_kwargs.enable_thinking, .max_tokens]')" >> "$mock/log"
[[ "\$m" == "${CAND}" ]] && s="\${MC_SLEEP_CAND:-0.1}" || s="\${MC_SLEEP_CHAMP:-0.1}"
# With the harness on the virtual clock the call takes exactly s; on the real
# one (the GPU test) it sleeps, holding the busy file the ioreg stub reads.
if [[ -n "\${DELEGATE_EVAL_CLOCK:-}" ]]; then
  awk -v s="\$s" '{ printf "%.3f", \$1 + s }' "\$DELEGATE_EVAL_CLOCK" > "\$DELEGATE_EVAL_CLOCK.new" && mv "\$DELEGATE_EVAL_CLOCK.new" "\$DELEGATE_EVAL_CLOCK"
else
  touch "$mock/busy"; sleep "\$s"; rm -f "$mock/busy"
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
printf '#!/usr/bin/env bash\necho 0\n' > "$mock/osascript"
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock/caffeinate"
chmod +x "$mock"/*

# Stubs: each logs its argv, its pinned model and its cwd, then answers.
cat > "$stubs/replay-recipe.sh" <<'EOF'
#!/usr/bin/env bash
echo "replay $*" >> "$STUB_LOG"
r=""; while (( $# > 0 )); do [[ "$1" == --recipe ]] && r="$2"; shift; done
v=$(printf '%s' "${STUB_REPLAY:-}" | tr ',' '\n' | sed -n "s/^$r=//p")
case "${v:-INCONCLUSIVE}" in
  NONE) echo "replay-recipe: no replayable edited case" >&2; exit 3 ;;
  HOT) exit 75 ;;
  BROKEN) echo "replay-recipe: boom" >&2; exit 2 ;;
  ACCEPT) w=6; l=0; p="Sign test: p=0.016 (one-sided, 6 wins to 0)" ;;
  REJECT) w=0; l=6; p="Sign test: p=0.016 (one-sided, 6 losses to 0)" ;;
  *) w=2; l=2; p="" ;;
esac
echo "=== replay: $r (model comparison) ==="
printf '  %-10s %-20s %-8s %-18s %-18s %s\n' rej0000001 2026-09-01T10:00:00Z rewrote 0/2/1/0/0/0/0=3 0/1/0/1/0/0/0=2 WIN
printf '  %-10s %-20s %-8s %-18s %-18s %s\n' rej0000002 2026-09-02T10:00:00Z scaffold 1/0/3/0/0/0/0=4 0/0/2/2/0/0/0=4 tie
echo "Summary: n=$((w + l))  wins=$w  losses=$l  ties=0  errors=0"
[[ -n "$p" ]] && echo "$p"
echo "Verdict: ${v:-INCONCLUSIVE} — stub."
EOF
cat > "$stubs/verify-draft.sh" <<'EOF'
#!/usr/bin/env bash
echo "verify $DELEGATE_MODEL $DELEGATE_BASE_URL $*" >> "$STUB_LOG"
[[ -n "${STUB_VERIFY_FAIL:-}" ]] && { echo "verify-draft: the verifier is unavailable" >&2; exit 3; }
if [[ -n "${STUB_OFF_FORMAT:-}" && "$DELEGATE_MODEL" == cand-model ]]; then
  echo "verify-draft: the verifier answered with neither option letter (coverage 0); no score" >&2
  echo "verify-draft: no row could be scored" >&2; exit 3
fi
if [[ "$DELEGATE_MODEL" == cand-model ]]; then a="${STUB_AUROC_CAND:-0.900}"; t="${STUB_THRESHOLD_CAND:-0.81}"; else a="${STUB_AUROC_CHAMP:-0.900}"; t=0.77; fi
echo "verify-calibrate: model=$DELEGATE_MODEL errors=0 n=120 auroc=$a threshold=$t balanced_accuracy=0.880 accuracy=100/120 acc@0.5=90/120 recall supported=50/60 contradicted=28/30 unsupported=27/30 p50_ms=300"
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
# for the real one.
run() {
  PATH="$mock:$SAFE_PATH" DELEGATE_LOCAL_DATA_DIR="$data" DELEGATE_BASE_URL="http://champ.test/v1" \
    DELEGATE_EVAL_SCRIPTS="$stubs" DELEGATE_GPU_GATE=0 STUB_LOG="$TEST_ROOT/stub.log" \
    DELEGATE_EVAL_CLOCK="${DELEGATE_EVAL_CLOCK-$TEST_ROOT/clock}" \
    bash "$SCRIPT" "$@"
}
fresh() { rm -rf "$data/evals"; : > "$TEST_ROOT/stub.log"; : > "$mock/log"; printf '1000.000' > "$TEST_ROOT/clock"; }
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
assert_contains "seconds per call" "$out" "cost is reported"
assert_contains "ratio" "$out" "with the ratio"
assert_eq "$rows_before" "$(grep -c '' "$data/metrics.jsonl")" "no metrics row is written"
# The replay: each of the busiest recipes, edited cases only, candidate pinned.
assert_eq 3 "$(grep -c '^replay ' "$TEST_ROOT/stub.log")" "the replay runs the recipes in the metrics"
assert_contains "replay --recipe rp1 --candidate-model $CAND --candidate-base http://cand.test/v1 --edited-only --limit 20" \
  "$(cat "$TEST_ROOT/stub.log")" "on the edited cases, the candidate pinned to its base"
# Anchors are summed over the listed cases: champion 0/2/1 + 1/0/3 fields
# 2-4 give 2/4/0, candidate 1/0/1 + 0/2/2 give 1/2/3.
assert_eq " rp1 n=6 W6 L0 T0 p=0.016 ACCEPT 2/4/0 | 1/2/3" "$(printf '%s\n' "$out" | grep -E '^  rp1 ' | sed -E 's/ +/ /g')" \
  "a recipe line carries the tally, p, verdict and dropped/over/invented per arm"
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
# calls are counted and named in the reason, and a model that opens a lettered
# question with anything but a letter stops, once, rather than holding open.
fresh
out=$(MC_THINK=1 MC_SLEEP_CAND=0.4 MC_SLEEP_CHAMP=0.1 STUB_OFF_FORMAT=1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "  output tokens per call   4096 / 50" "$out" "output tokens per call are reported"
assert_contains "  ran to max_tokens        2 of 2 / 0 of 2" "$out" "and the calls that ran to max_tokens"
assert_contains "  reasoning trace          2 of 2 / 0 of 2 (thinking requested off)" "$out" "and the calls that carried a reasoning trace"
assert_contains "and it reasoned before answering on 2 of 2 calls although thinking was off" "$out" "the cost reason names the thinking"
assert_contains "grounding: the candidate does not answer decide.sh's lettered questions" "$out" "an off-format answer to the verifier stops"
assert_eq 1 "$(printf '%s\n' "$out" | tail -n 1 | grep -o "does not answer decide.sh's lettered questions" | grep -c '')" \
  "named once though the trigger gate failed the same way"
assert_contains "  candidate no score: verify-draft: no row could be scored" "$out" "the last error line is shown"
# A call that spent its budget thinking and came back empty cost the GPU and
# failed its delegation: it counts in the cost and stops the card.
fresh
out=$(MC_EMPTY=1 MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "  empty answer             2 of 2 / 0 of 2" "$out" "an empty answer is counted, not dropped as an error"
assert_contains "no answer: the candidate returned empty content on 2 of 2 calls" "$out" "and stops the card"

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
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: HOLD — it matches the champion without being cheaper or better" "$out" "a tie on every step is a hold"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 STUB_VERIFY_FAIL=1 run --model "$CAND" --base http://cand.test/v1 --prompts 2 2>/dev/null)
assert_contains "Verdict: INCONCLUSIVE — grounding: the verifier question could not be scored on the candidate" "$out" "a verifier that cannot score holds the verdict open"
assert_eq "" "$(find "$data/evals/cache" -name '*.grounding.*')" "and a failed score is not cached"
fresh
out=$(STUB_REPLAY="rp1=BROKEN" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "replay: rp1 did not run (exit 2)" "$out" "a replay that fails holds the verdict open"
fresh
out=$(MC_SLEEP_CAND=0.5 MC_SLEEP_CHAMP=0.5 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --grounding "$data/none.jsonl" 2>/dev/null)
assert_contains "not measured: no labelled set at $data/none.jsonl" "$out" "no grounding set is reported"
assert_contains "Verdict: HOLD" "$out" "and does not hold the verdict open"
fresh
out=$(STUB_THRESHOLD_CAND=0.9999 run --model "$CAND" --base http://cand.test/v1 --skip cost 2>/dev/null)
assert_contains "scores pile up near 1" "$out" "a saturated verifier threshold is called out"

echo "== the heat gate and the GPU measure =="
fresh
EC=0; out=$(STUB_REPLAY="rp1=HOT" run --model "$CAND" --base http://cand.test/v1 --skip cost 2>&1) || EC=$?
assert_eq 75 "$EC" "a replay stopped by the heat gate stops the run with 75"
assert_contains "rerun to resume" "$out" "and says how to resume"
fresh
# The one test on the real clock: ioreg is sampled in real time.
out=$(DELEGATE_EVAL_CLOCK='' MC_UTIL=1 MC_SLEEP_CAND=1.2 MC_SLEEP_CHAMP=0.6 run --model "$CAND" --base http://cand.test/v1 --prompts 2 --skip replay 2>/dev/null)
assert_contains "GPU busy-seconds/call" "$out" "with ioreg readable, GPU busy-seconds are reported"
assert_contains "(GPU busy-seconds per call)" "$out" "and are the cost measure"
assert_true "the slower candidate costs more GPU time" awk -v r="$(card .cost.ratio)" 'BEGIN { exit !(r > 1) }'

echo "== the recipes come from the metrics when not named =="
fresh
run --model "$CAND" --base http://cand.test/v1 --skip cost,grounding,trigger >/dev/null 2>&1
assert_eq "rp1 rp2 rp3" "$(sed -n 's/^replay --recipe \([^ ]*\) .*/\1/p' "$TEST_ROOT/stub.log" | tr '\n' ' ' | sed 's/ $//')" \
  "busiest first"
: > "$TEST_ROOT/stub.log"
run --model "$CAND" --base http://cand.test/v1 --skip cost,grounding,trigger --recipes rp2 >/dev/null 2>&1
assert_eq "rp2" "$(sed -n 's/^replay --recipe \([^ ]*\) .*/\1/p' "$TEST_ROOT/stub.log")" "--recipes names them"

finish
