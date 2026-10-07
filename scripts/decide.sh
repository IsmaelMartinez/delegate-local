#!/usr/bin/env bash
# decide.sh — answer a SystemOne decision request with per-option probabilities
# (ADR 0033; spike #636, epic #642). Two backends share one output shape, so
# any experiment can compare them row by row:
#
#   logprob  the default: each question asked of the resident tier model as a
#            lettered multiple choice with max_tokens 1, scored from the first
#            token's top logprobs and renormalised over the option letters.
#            One chat call per question.
#   clef     POST {DELEGATE_CLEF_URL}/v1/systemone — Cloudflare Clef served locally
#            (a uv script in the data dir's spikes/clef/) or any SystemOne
#            endpoint; every question of a request scored in one pass, so it
#            is the backend for many-question batch jobs. The repo ships no server.
#
# Usage:  decide.sh [--backend logprob|clef] [--tier TIER] < request.json
#
# request.json is a SystemOne body: {"state": string|object, "questions":
# {id: {"type": "noul"|"choice"|"score", "instructions": "...", "criteria":
# ...}}, "model": optional}. Options follow Clef's question_options(): noul is
# true/false, choice is the sorted criteria keys, score is the criteria index.
#
# Output (stdout, one JSON object):
#   {"backend","model","latency_ms","answers":{id:{"type","probabilities":{opt:p}}}}
# A logprob answer also carries "coverage": the raw probability mass the
# option letters held among the top logprobs before renormalising.
#
# Env:  DELEGATE_CLEF_URL (default http://127.0.0.1:8765), DELEGATE_CLEF_MODEL (default
#       clef-flash), DELEGATE_DECIDE_TIMEOUT (seconds, default 120).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend="logprob"
tier="prose"
need_value() { [[ -n "${2:-}" ]] || { echo "decide: $1 requires a value" >&2; exit 2; }; }
while (( $# > 0 )); do
  case "$1" in
    --backend) need_value "$@"; backend="$2"; shift 2 ;;
    --tier) need_value "$@"; tier="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "decide: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

request=$(cat)
if ! jq -e '(.state != null) and (.questions | type == "object" and length > 0)' <<<"$request" >/dev/null 2>&1; then
  echo "decide: stdin must be a SystemOne request with state and at least one question" >&2
  exit 2
fi
timeout="${DELEGATE_DECIDE_TIMEOUT:-120}"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# The option list for one question, as [[key, description], ...].
options_jq='
  def options:
    if .type == "noul" then
      ({"true": "The proposition is true or the answer is yes.",
        "false": "The proposition is false or the answer is no."} + (.criteria // {})) as $c
      | [["true", $c["true"]], ["false", $c["false"]]]
    elif .type == "choice" then .criteria | to_entries | sort_by(.key) | map([.key, .value])
    else .criteria | to_entries | map([(.key | tostring), .value])
    end;'

case "$backend" in
  clef)
    url="${DELEGATE_CLEF_URL:-http://127.0.0.1:8765}"
    body=$(jq -c --arg m "${DELEGATE_CLEF_MODEL:-clef-flash}" '.model //= $m' <<<"$request")
    t0=$(now_ms)
    if ! response=$(curl -sS --fail --max-time "$timeout" -H 'Content-Type: application/json' \
         --data-binary @- "$url/v1/systemone" <<<"$body"); then
      echo "decide: clef request to $url failed" >&2
      exit 1
    fi
    t1=$(now_ms)
    jq -c --argjson ms "$((t1 - t0))" '
      {backend: "clef", model: .model, latency_ms: $ms,
       answers: (.answers | with_entries(.value |= (
         if .type == "noul" then {type, probabilities: {"true": .noul, "false": (1 - .noul)}}
         else {type, probabilities} end)))}' <<<"$response"
    ;;
  logprob)
    resolved=$(bash "$script_dir/pick-model.sh" --print-resolution "$tier") || {
      echo "decide: no model resolves for tier '$tier'" >&2; exit 1; }
    base="${resolved%%$'\t'*}"
    model="${resolved#*$'\t'}"
    state=$(jq -r 'if (.state | type) == "string" then .state else (.state | tojson) end' <<<"$request")
    answers='{}'
    t0=$(now_ms)
    while IFS= read -r qid; do
      question=$(jq -c --arg q "$qid" '.questions[$q]' <<<"$request")
      opts=$(jq -c "$options_jq options" <<<"$question")
      n=$(jq 'length' <<<"$opts")
      if (( n < 2 || n > 26 )); then
        echo "decide: question '$qid' has $n options; the logprob control needs 2-26" >&2
        exit 2
      fi
      prompt=$(jq -r --arg state "$state" --arg q "$qid" '
        "Read the state and answer the question with exactly one option letter.\n\nState:\n"
        + $state + "\n\nQuestion (" + $q + "): " + (.question.instructions // $q) + "\n\nOptions:\n"
        + ([.opts | to_entries[] | "\([65 + .key] | implode): \(.value[0]) — \(.value[1] | tostring)"] | join("\n"))
        + "\n\nAnswer with one letter only."' <<<"{\"question\":$question,\"opts\":$opts}")
      # top_logprobs 10: mlx_lm.server drops the connection above 10.
      payload=$(jq -nc --arg m "$model" --arg p "$prompt" '
        {model: $m, temperature: 0, max_tokens: 1, stream: false,
         logprobs: true, top_logprobs: 10,
         chat_template_kwargs: {enable_thinking: false},
         messages: [{role: "user", content: $p}]}')
      if ! response=$(curl -sS --fail --max-time "$timeout" -H 'Content-Type: application/json' \
           --data-binary @- "$base/chat/completions" <<<"$payload"); then
        echo "decide: logprob request to $base failed" >&2
        exit 1
      fi
      # A provider that ignores logprobs returns no distribution; uniform
      # scores made up from nothing would pass for a control result.
      if ! jq -e '(.choices[0].logprobs.content[0].top_logprobs // []) | length > 0' <<<"$response" >/dev/null; then
        echo "decide: $base returned no top_logprobs for '$qid'; the logprob control needs a provider that supports them" >&2
        exit 1
      fi
      # Tokens may arrive byte-level encoded ("ĠA" for " A"); strip that marker
      # and whitespace, then sum the mass per option letter.
      answer=$(jq -c --argjson opts "$opts" --arg type "$(jq -r '.type' <<<"$question")" '
        (.choices[0].logprobs.content[0].top_logprobs // []) as $top
        | [range(0; $opts | length) as $i
           | {key: $opts[$i][0], letter: ([65 + $i] | implode)}] as $keys
        | [$keys[] as $k
           | {key: $k.key,
              p: ([$top[] | select((.token | gsub("^(Ġ|\\s)+|\\s+$"; "")) == $k.letter) | (.logprob | exp)] | add // 0)}] as $mass
        | ([$mass[].p] | add) as $total
        | {type: $type,
           coverage: ([$total, 1] | min | . * 10000 | round / 10000),
           probabilities: ($mass | map({(.key): (if $total > 0 then (.p / $total * 10000 | round / 10000) else (1 / ($opts | length)) end)}) | add)}' <<<"$response")
      answers=$(jq -c --arg q "$qid" --argjson a "$answer" '. + {($q): $a}' <<<"$answers")
    done < <(jq -r '.questions | keys_unsorted[]' <<<"$request")
    t1=$(now_ms)
    jq -nc --arg m "$model" --argjson ms "$((t1 - t0))" --argjson a "$answers" \
      '{backend: "logprob", model: $m, latency_ms: $ms, answers: $a}'
    ;;
  *) echo "decide: --backend must be clef or logprob" >&2; exit 2 ;;
esac
