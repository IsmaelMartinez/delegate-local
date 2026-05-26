#!/usr/bin/env bash
# Run trigger-correctness evals against evals/eval-set.json.
#
# Modes:
#   default (shape):  validate JSON, assert balance and required fields.
#   --api:            score every query in a single Anthropic API call (paid).
#                     Requires ANTHROPIC_API_KEY.
#   --ollama [model]: score every query in a single local Ollama call (free).
#                     Defaults to scripts/pick-model.sh code if no model is
#                     given. Trigger eval is closed-form binary classification —
#                     the same shape SKILL.md identifies as the code tier's
#                     strength — so the code-tier resolution is more reliable
#                     than the reasoning-tier resolution on this workload.
#                     Override with an explicit model name when measuring a
#                     different scorer; thresholds in the eval set are the
#                     calibration target, not the chosen model. Requires the
#                     Ollama daemon at OLLAMA_HOST (default http://localhost:11434).
#   --github-models [model]:
#                     score every query in a single GitHub Models call (free up
#                     to the per-model rate-limit tier). Defaults to
#                     openai/gpt-4o-mini, which is on the "low" rate-limit
#                     tier (150 RPD) and is sufficient for binary trigger
#                     classification. Auth via the GITHUB_TOKEN env var, which
#                     GitHub Actions workflows auto-provision when the job
#                     declares `permissions: models: read`. Locally,
#                     `GITHUB_TOKEN=$(gh auth token)` is the easiest way to run
#                     this mode.
#
# Batching: one API call per run, not one per query. The judge receives the
# full eval set as a JSON array and replies with a JSON object of verdicts
# keyed by query id. This collapses ~23 requests/run into 1 so a normal day
# of CI iteration stays under the GitHub Models 150 RPD free-tier quota
# (issue #62).
#
# All three scoring modes use the same SKILL.md-frontmatter-as-trigger-surface
# prompt and the same recall / negative-precision thresholds from the eval set.
# Ollama is the recommended local pre-merge gate (dogfooded routing); GitHub
# Models is the recommended CI gate (free, no secret to configure); Anthropic
# remains for the rare case Claude-grade scoring is wanted.
#
# Usage:  eval-skill-triggers.sh [--api | --ollama [model] | --github-models [model]] [--eval-set path] [--skill path]
# Env:    ANTHROPIC_API_KEY (required for --api)
#         OLLAMA_HOST       (optional for --ollama; default localhost:11434)
#         GITHUB_TOKEN      (required for --github-models)
# Exit:   0 pass, 1 threshold breach / shape error, 2 usage / config / parse error.

set -uo pipefail

mode="shape"
backend=""
ollama_model=""
github_model=""
eval_set="evals/eval-set.json"
skill="SKILL.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) mode="api"; backend="anthropic"; shift ;;
    --ollama)
      mode="api"; backend="ollama"; shift
      # Optional model name immediately after --ollama; if the next arg starts
      # with -- treat it as the next flag instead.
      if [[ $# -gt 0 && "$1" != --* ]]; then ollama_model="$1"; shift; fi
      ;;
    --github-models)
      mode="api"; backend="github_models"; shift
      if [[ $# -gt 0 && "$1" != --* ]]; then github_model="$1"; shift; fi
      ;;
    --eval-set) eval_set="$2"; shift 2 ;;
    --skill) skill="$2"; shift 2 ;;
    *) echo "usage: eval-skill-triggers.sh [--api | --ollama [model] | --github-models [model]] [--eval-set path] [--skill path]" >&2; exit 2 ;;
  esac
done

[[ -f "$eval_set" ]] || { echo "missing eval set: $eval_set" >&2; exit 2; }
[[ -f "$skill" ]]    || { echo "missing skill: $skill" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Shape checks (always run).
total=$(jq '.queries | length' "$eval_set")
pos=$(jq '[.queries[] | select(.expect == "trigger")] | length' "$eval_set")
neg=$(jq '[.queries[] | select(.expect == "no-trigger")] | length' "$eval_set")
missing_fields=$(jq '[.queries[] | select((.id // "") == "" or (.tag // "") == "" or (.expect // "") == "" or (.query // "") == "")] | length' "$eval_set")

echo "shape: total=$total positive=$pos negative=$neg missing-fields=$missing_fields"

(( total >= 16 ))         || { echo "FAIL: need >=16 total queries" >&2; exit 1; }
(( pos >= 8 ))            || { echo "FAIL: need >=8 positives (got $pos)" >&2; exit 1; }
(( neg >= 8 ))            || { echo "FAIL: need >=8 negatives (got $neg)" >&2; exit 1; }
(( missing_fields == 0 )) || { echo "FAIL: $missing_fields queries missing fields" >&2; exit 1; }

if [[ "$mode" == "shape" ]]; then
  echo "OK shape mode (run with --api, --ollama, or --github-models for trigger-accuracy check)"
  exit 0
fi

# Scoring mode (Anthropic, Ollama, or GitHub Models backend).
command -v curl >/dev/null || { echo "curl not on PATH" >&2; exit 2; }

# Extract the frontmatter description from SKILL.md (used as the trigger surface).
# Capture indented continuation lines so YAML block scalars / folded multi-line
# descriptions are preserved in full — truncation here would skew recall.
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
  ollama)
    if [[ -n "$ollama_model" ]]; then
      scoring_model="$ollama_model"
    else
      pick="$(dirname "$0")/pick-model.sh"
      [[ -x "$pick" ]] || { echo "pick-model.sh not found at $pick" >&2; exit 2; }
      scoring_model=$(bash "$pick" code 2>/dev/null) || true
      [[ -n "$scoring_model" ]] || { echo "pick-model.sh code returned empty (no installed model for the tier?)" >&2; exit 2; }
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
    ollama)
      local host="${OLLAMA_HOST:-http://localhost:11434}"
      local payload resp
      payload=$(jq -nc --arg model "$scoring_model" --arg sys "$system_prompt" --arg user "$user_payload" --argjson max "$out_budget" '{
        model: $model,
        system: $sys,
        prompt: $user,
        think: false,
        format: "json",
        options: {temperature: 0, num_predict: $max},
        stream: false
      }')
      resp=$(curl -fsS --max-time 120 "$host/api/generate" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null) || return 1
      jq -r '.response // empty' <<<"$resp"
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
      # Free-tier limit is 15 RPM on low rate-limit-tier models. We only make
      # one request per run so RPM is not the concern; the retry loop exists
      # to recover from transient 429s when the daily window is near reset.
      # --max-time bounds each attempt so a long Retry-After never silently
      # stalls CI (issue #62).
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
          # Cap the retry-after wait at 60s so a multi-hour Retry-After (the
          # daily-bucket-reset case from issue #62) doesn't stall CI. The
          # caller surfaces the resulting transport error as a fast failure.
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

# Validate JSON shape. If the model emitted prose around the JSON, try to
# extract the first {...} block. jq's `try fromjson` returns empty on bad
# input which we surface as a parse error.
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

# Build a TSV-backed verdict lookup (bash 3 has no associative arrays). One
# row per verdict: <id>\t<verdict>. Normalise verdict to uppercase, alpha-only.
verdict_map=$(mktemp)
trap 'rm -f "$verdict_map"' EXIT
jq -r '.[] | "\(.id)\t\(.verdict)"' <<<"$verdicts_json" \
  | awk -F'\t' '{ v=toupper($2); gsub(/[^A-Z]/, "", v); printf "%s\t%s\n", $1, v }' \
  > "$verdict_map"

tp=0; fn=0; tn=0; fp=0
missing_verdicts=0
while read -r row; do
  id=$(jq -r '.id'     <<<"$row")
  expect=$(jq -r '.expect' <<<"$row")
  query=$(jq -r '.query'   <<<"$row")
  verdict=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$verdict_map")
  if [[ -z "$verdict" ]]; then
    missing_verdicts=$((missing_verdicts + 1))
    verdict="MISSING"
  fi
  jq -nc --arg id "$id" --arg expect "$expect" --arg verdict "$verdict" --arg query "$query" \
    '{id:$id, expect:$expect, verdict:$verdict, query:$query}' >> "$results_file"
  # Classify the verdict. Order matters: NOTRIGGER must be checked before
  # TRIGGER because the latter is a prefix of the former. Glob match tolerates
  # stray punctuation that survived the alpha-only normalisation (it cannot,
  # in practice, but the check costs nothing). Garbage / missing verdicts
  # count as a miss against the expected outcome — strict scoring discourages
  # eval-set ambiguity.
  is_trigger=0; is_notrigger=0
  if   [[ "$verdict" == NOTRIGGER* ]]; then is_notrigger=1
  elif [[ "$verdict" == TRIGGER* ]];   then is_trigger=1
  fi
  if [[ "$expect" == "trigger" ]]; then
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
echo "raw:     $results_file"

ok=1
awk -v r="$recall"   -v t="$recall_threshold" 'BEGIN{ exit !(r+0 >= t+0) }' || ok=0
awk -v p="$neg_prec" -v t="$prec_threshold"   'BEGIN{ exit !(p+0 >= t+0) }' || ok=0

if (( ok == 0 )); then
  echo "FAIL: recall<$recall_threshold or negative-precision<$prec_threshold" >&2
  exit 1
fi
echo "OK trigger evals ($backend)"
