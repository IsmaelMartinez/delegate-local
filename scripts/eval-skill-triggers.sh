#!/usr/bin/env bash
# Run trigger-correctness evals against evals/eval-set.json.
#
# Modes:
#   default (shape):  validate JSON, assert balance and required fields.
#   --api:            one Anthropic API call (paid); needs ANTHROPIC_API_KEY.
#   --local [model]:  one local provider call (free); defaults to
#                     pick-model.sh code, since trigger eval is closed-form
#                     binary classification. The thresholds in the eval set
#                     are the calibration target, not the chosen model.
#   --github-models [model]:
#                     one GitHub Models call (free up to the rate-limit tier);
#                     defaults to openai/gpt-4o-mini. Auth via GITHUB_TOKEN,
#                     auto-provisioned in Actions under `permissions: models:
#                     read`; locally `GITHUB_TOKEN=$(gh auth token)`.
#
# One batched call per run, not one per query, so a day of CI iteration stays
# under the GitHub Models 150 RPD free tier (#62). All modes use the SKILL.md
# frontmatter description as the trigger surface and the same thresholds.
#
# Usage:  eval-skill-triggers.sh [--api | --local [model] | --github-models [model]] [--eval-set path] [--skill path]
# Env:    ANTHROPIC_API_KEY (required for --api)
#         DELEGATE_BASE_URL (optional for --local; pick-model.sh owns the default)
#         GITHUB_TOKEN      (required for --github-models)
# Exit:   0 pass, 1 threshold breach / shape error, 2 usage / config / parse error.

set -uo pipefail

mode="shape"
backend=""
local_model=""
local_base=""
github_model=""
eval_set="evals/eval-set.json"
skill="SKILL.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) mode="api"; backend="anthropic"; shift ;;
    --local)
      mode="api"; backend="local"; shift
      # Optional model name; a following --flag is not one.
      if [[ $# -gt 0 && "$1" != --* ]]; then local_model="$1"; shift; fi
      ;;
    --github-models)
      mode="api"; backend="github_models"; shift
      if [[ $# -gt 0 && "$1" != --* ]]; then github_model="$1"; shift; fi
      ;;
    --eval-set) eval_set="$2"; shift 2 ;;
    --skill) skill="$2"; shift 2 ;;
    *) echo "usage: eval-skill-triggers.sh [--api | --local [model] | --github-models [model]] [--eval-set path] [--skill path]" >&2; exit 2 ;;
  esac
done

[[ -f "$eval_set" ]] || { echo "missing eval set: $eval_set" >&2; exit 2; }
[[ -f "$skill" ]]    || { echo "missing skill: $skill" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Shape checks count only GATED rows, so a set cannot pass shape with too few
# gated cases to score. `!= false`, not `// false`: an absent gate is null,
# and null != false is true, so an entry is gated unless explicitly gate:false.
total=$(jq '.queries | length' "$eval_set")
pos=$(jq '[.queries[] | select(.expect == "trigger" and (.gate != false))] | length' "$eval_set")
neg=$(jq '[.queries[] | select(.expect == "no-trigger" and (.gate != false))] | length' "$eval_set")
diagnostic=$(jq '[.queries[] | select(.gate == false)] | length' "$eval_set")
missing_fields=$(jq '[.queries[] | select((.id // "") == "" or (.tag // "") == "" or (.expect // "") == "" or (.query // "") == "")] | length' "$eval_set")

echo "shape: total=$total positive=$pos negative=$neg diagnostic=$diagnostic missing-fields=$missing_fields"

(( total >= 16 ))         || { echo "FAIL: need >=16 total queries" >&2; exit 1; }
(( pos >= 8 ))            || { echo "FAIL: need >=8 gated positives (got $pos)" >&2; exit 1; }
(( neg >= 8 ))            || { echo "FAIL: need >=8 gated negatives (got $neg)" >&2; exit 1; }
(( missing_fields == 0 )) || { echo "FAIL: $missing_fields queries missing fields" >&2; exit 1; }

if [[ "$mode" == "shape" ]]; then
  echo "OK shape mode (run with --api, --local, or --github-models for trigger-accuracy check)"
  exit 0
fi

# Scoring mode (Anthropic, a local provider, or GitHub Models).
command -v curl >/dev/null || { echo "curl not on PATH" >&2; exit 2; }

# The frontmatter description is the trigger surface; indented continuation
# lines are kept so a folded multi-line description is not truncated.
description=$(awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; next} c==1' "$skill" \
  | awk '/^description:/{sub(/^description: */,""); print; while(getline && /^[[:space:]]+/) print}')
if [[ -z "$description" ]]; then echo "could not parse description from $skill" >&2; exit 2; fi

recall_threshold=$(jq -r '.thresholds.positive_recall // 0.9' "$eval_set")
prec_threshold=$(jq -r '.thresholds.negative_precision // 0.9' "$eval_set")
skill_name=$(jq -r '.skill // "delegate-local"' "$eval_set")

# Resolve the scoring model per backend.
case "$backend" in
  anthropic)
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "ANTHROPIC_API_KEY not set" >&2; exit 2; }
    scoring_model=$(jq -r '.model // "claude-sonnet-4-6"' "$eval_set")
    ;;
  local)
    pick="$(dirname "$0")/pick-model.sh"
    [[ -x "$pick" ]] || { echo "pick-model.sh not found at $pick" >&2; exit 2; }
    if [[ -n "$local_model" ]]; then
      # A hand-named scorer can live on a provider the code tier did not pick;
      # dispatching to the wrong base is a silently different model at worst.
      scoring_model="$local_model"
      while IFS= read -r _b; do
        _b="${_b%/}"
        if curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" "$_b/models" 2>/dev/null \
             | jq -e --arg m "$scoring_model" 'any(.data[]; .id == $m)' >/dev/null 2>&1; then
          local_base="$_b"; break
        fi
      done < <(bash "$pick" --print-providers)
      [[ -n "$local_base" ]] || { echo "no provider serves model '$scoring_model'" >&2; exit 2; }
    else
      # One call for both answers, so a dead provider is probed once.
      _resolved=$(bash "$pick" --print-resolution code 2>/dev/null) \
        || { echo "pick-model.sh code returned empty (no provider serving a model for the tier?)" >&2; exit 2; }
      local_base="${_resolved%%	*}"
      scoring_model="${_resolved#*	}"
    fi
    ;;
  github_models)
    [[ -n "${GITHUB_TOKEN:-}" ]] || { echo "GITHUB_TOKEN not set (run with GITHUB_TOKEN=\$(gh auth token) or in a workflow with permissions: models: read)" >&2; exit 2; }
    scoring_model="${github_model:-openai/gpt-4o-mini}"
    ;;
esac

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
results_dir="evals/results"
mkdir -p "$results_dir"
results_file="$results_dir/$run_id-$backend.jsonl"
: > "$results_file"

# Output token budget: ~30 tokens per verdict (id + JSON syntax) is generous.
# Cap at 4000 to stay inside the GitHub Models free-tier 4000-out limit.
out_budget=$(( total * 30 ))
(( out_budget > 4000 )) && out_budget=4000

system_prompt="You are a trigger judge for a skill called $skill_name. Judge each query INDEPENDENTLY of the others — every query gets its own verdict based solely on whether the skill description below should fire on that query in isolation. Do not let the presence of other queries in the batch influence any single verdict.

Reply with ONLY a JSON object of this exact shape:
{\"verdicts\":[{\"id\":\"<id>\",\"verdict\":\"TRIGGER\"},{\"id\":\"<id>\",\"verdict\":\"NOTRIGGER\"}]}
Use the ids exactly as provided. Use only the literal strings TRIGGER or NOTRIGGER. Cover every input id exactly once. No prose, no markdown fences, no explanation.

Skill description:
$description"

# Build the user message: a JSON array of {id, query} objects from the eval set.
user_payload=$(jq -c '[.queries[] | {id, query}]' "$eval_set")

# Run the single batched scoring call. Returns the raw JSON verdicts text on
# stdout. Exits non-zero on transport error.
score_batch() {
  case "$backend" in
    anthropic)
      local payload resp
      payload=$(jq -nc --arg model "$scoring_model" --arg sys "$system_prompt" --arg user "$user_payload" --argjson max "$out_budget" '{
        model: $model, max_tokens: $max,
        system: $sys,
        messages: [{role:"user", content:$user}]
      }')
      resp=$(curl -fsS --max-time 60 https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null) || return 1
      jq -r '.content[0].text // empty' <<<"$resp"
      ;;
    local)
      local payload resp
      # Same chat-completions envelope as the github_models arm, so the local
      # gate is not wired to one daemon's native API.
      payload=$(jq -nc --arg model "$scoring_model" --arg sys "$system_prompt" --arg user "$user_payload" --argjson max "$out_budget" '{
        model: $model,
        messages: [{role:"system", content:$sys}, {role:"user", content:$user}],
        temperature: 0,
        max_tokens: $max,
        response_format: {type: "json_object"},
        stream: false
      }')
      resp=$(curl -fsS --max-time 120 "$local_base/chat/completions" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null) || return 1
      jq -r '.choices[0].message.content // empty' <<<"$resp"
      ;;
    github_models)
      local host="${GITHUB_MODELS_HOST:-https://models.github.ai}"
      local payload resp http_code retry_after attempt=0
      payload=$(jq -nc --arg model "$scoring_model" --arg sys "$system_prompt" --arg user "$user_payload" --argjson max "$out_budget" '{
        model: $model,
        messages: [{role:"system", content:$sys}, {role:"user", content:$user}],
        temperature: 0,
        max_tokens: $max,
        response_format: {type: "json_object"}
      }')
      # The retry loop recovers from a transient 429; --max-time bounds each
      # attempt so a long Retry-After never silently stalls CI (#62).
      while (( attempt < 3 )); do
        local headers_file body_file
        headers_file=$(mktemp); body_file=$(mktemp)
        http_code=$(curl -sS --max-time 60 -o "$body_file" -D "$headers_file" -w '%{http_code}' \
          "$host/inference/chat/completions" \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$payload" 2>/dev/null) || { rm -f "$headers_file" "$body_file"; return 1; }
        if [[ "$http_code" == "429" ]]; then
          retry_after=$(awk 'tolower($1) == "retry-after:" { gsub(/[^0-9]/, "", $2); print $2; exit }' "$headers_file")
          rm -f "$headers_file" "$body_file"
          [[ -z "$retry_after" || "$retry_after" -eq 0 ]] && retry_after=20
          # Capped so a multi-hour Retry-After (daily bucket reset) cannot stall CI.
          (( retry_after > 60 )) && retry_after=60
          sleep "$retry_after"
          attempt=$((attempt + 1))
          continue
        fi
        if [[ "$http_code" != "200" ]]; then
          rm -f "$headers_file" "$body_file"
          return 1
        fi
        resp=$(cat "$body_file")
        rm -f "$headers_file" "$body_file"
        jq -r '.choices[0].message.content // empty' <<<"$resp"
        return 0
      done
      return 1
      ;;
  esac
}

echo "scoring: backend=$backend model=$scoring_model"

raw=$(score_batch) || { echo "$backend transport error" >&2; exit 2; }

# Strip any code fences the model might emit despite the no-fences instruction.
raw=${raw//\`\`\`json/}
raw=${raw//\`\`\`/}

# If the model emitted prose around the JSON, fall back to the first {...} block.
verdicts_json=$(jq -c '.verdicts // empty' <<<"$raw" 2>/dev/null || true)
if [[ -z "$verdicts_json" || "$verdicts_json" == "null" ]]; then
  # Fallback: extract the first balanced JSON object substring and re-parse.
  extracted=$(printf '%s' "$raw" | perl -0777 -ne 'if (/(\{.*\})/s) { print $1 }')
  verdicts_json=$(jq -c '.verdicts // empty' <<<"$extracted" 2>/dev/null || true)
fi
if [[ -z "$verdicts_json" || "$verdicts_json" == "null" ]]; then
  echo "$backend response did not contain a parseable verdicts array" >&2
  printf 'raw response (first 400 chars): %s\n' "${raw:0:400}" >&2
  exit 2
fi

# TSV-backed lookup (bash 3 has no associative arrays): <id>\t<VERDICT>.
verdict_map=$(mktemp)
trap 'rm -f "$verdict_map"' EXIT
jq -r '.[] | "\(.id)\t\(.verdict)"' <<<"$verdicts_json" \
  | awk -F'\t' '{ v=toupper($2); gsub(/[^A-Z]/, "", v); printf "%s\t%s\n", $1, v }' \
  > "$verdict_map"

tp=0; fn=0; tn=0; fp=0
# Diagnostic counters (#277): `"gate": false` queries (the embedded-sub-step
# cases) are scored and reported but never fold into the pass/fail gate,
# since gating on them would wedge an advisory eval.
dtp=0; dfn=0; dtn=0; dfp=0; diag=0
missing_verdicts=0
while read -r row; do
  id=$(jq -r '.id'     <<<"$row")
  expect=$(jq -r '.expect' <<<"$row")
  query=$(jq -r '.query'   <<<"$row")
  # Explicit compare, NOT `.gate // true`: jq treats false as absent there.
  gate=$(jq -r 'if .gate == false then "false" else "true" end' <<<"$row")
  verdict=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$verdict_map")
  if [[ -z "$verdict" ]]; then
    missing_verdicts=$((missing_verdicts + 1))
    verdict="MISSING"
  fi
  jq -nc --arg id "$id" --arg expect "$expect" --arg verdict "$verdict" --arg query "$query" --argjson gate "$gate" \
    '{id:$id, expect:$expect, verdict:$verdict, query:$query, gate:$gate}' >> "$results_file"
  # NOTRIGGER must be checked before TRIGGER, which is a prefix of it. A
  # garbage or missing verdict counts as a miss against the expected outcome.
  is_trigger=0; is_notrigger=0
  if   [[ "$verdict" == NOTRIGGER* ]]; then is_notrigger=1
  elif [[ "$verdict" == TRIGGER* ]];   then is_trigger=1
  fi
  if [[ "$gate" == "false" ]]; then
    diag=$((diag+1))
    if [[ "$expect" == "trigger" ]]; then
      if (( is_trigger )); then dtp=$((dtp+1)); else dfn=$((dfn+1)); fi
    else
      if (( is_notrigger )); then dtn=$((dtn+1)); else dfp=$((dfp+1)); fi
    fi
  elif [[ "$expect" == "trigger" ]]; then
    if (( is_trigger )); then tp=$((tp+1)); else fn=$((fn+1)); fi
  else
    if (( is_notrigger )); then tn=$((tn+1)); else fp=$((fp+1)); fi
  fi
done < <(jq -c '.queries[]' "$eval_set")

# Compute metrics with awk (bash has no float).
recall=$(awk -v tp="$tp" -v fn="$fn" 'BEGIN{ if(tp+fn==0) print 0; else printf "%.3f", tp/(tp+fn) }')
neg_prec=$(awk -v tn="$tn" -v fp="$fp" 'BEGIN{ if(tn+fp==0) print 0; else printf "%.3f", tn/(tn+fp) }')

if (( missing_verdicts > 0 )); then
  echo "warning: $missing_verdicts verdicts missing from batched response (counted as misses)" >&2
fi

echo "results: tp=$tp fn=$fn tn=$tn fp=$fp recall=$recall negative-precision=$neg_prec"
if (( diag > 0 )); then
  # Informational only, never gates.
  drecall=$(awk -v tp="$dtp" -v fn="$dfn" 'BEGIN{ if(tp+fn==0) print "n/a"; else printf "%.3f", tp/(tp+fn) }')
  echo "diagnostic (non-gating, embedded sub-step): dtp=$dtp dfn=$dfn embedded-recall=$drecall"
fi
echo "raw:     $results_file"

ok=1
awk -v r="$recall"   -v t="$recall_threshold" 'BEGIN{ exit !(r+0 >= t+0) }' || ok=0
awk -v p="$neg_prec" -v t="$prec_threshold"   'BEGIN{ exit !(p+0 >= t+0) }' || ok=0

if (( ok == 0 )); then
  echo "FAIL: recall<$recall_threshold or negative-precision<$prec_threshold" >&2
  exit 1
fi
echo "OK trigger evals ($backend)"
