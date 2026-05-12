#!/usr/bin/env bash
# Run the 6 fixture tasks against a single local-LLM backend and emit timing
# + output.
#
# Usage: runner.sh [--backend ollama|mlx] [--ollama-api] [--reps N] [--t3-snapshot YYYY-MM-DD] [--t4-snapshot YYYY-MM-DD] [--t5-snapshot YYYY-MM-DD] [--t6-snapshot YYYY-MM-DD] <model-name>
#
# --backend ollama|mlx (default ollama) selects which local HTTP backend to
#                     post to. ollama -> POST /api/generate with think:false
#                     on $OLLAMA_HOST (default http://localhost:11434). mlx ->
#                     POST /v1/chat/completions with chat_template_kwargs.
#                     enable_thinking:false on $MLX_HOST (default
#                     http://localhost:8080). The MLX backend uses the API
#                     path for every task (T1–T6) — there is no `ollama run`
#                     CLI equivalent for mlx_lm.server, and the chat-
#                     completions endpoint is the only way to make
#                     instruction-tuned models follow the chat template (the
#                     raw /v1/completions endpoint bypasses it and emits
#                     whitespace).
# --ollama-api        (default off) opts Ollama T1–T3 into the API path with
#                     think:false instead of `ollama run` CLI with reasoning
#                     on. The CLI path is kept as the default to preserve
#                     comparability with the 2026-04-28 and 2026-05-01
#                     baselines; --ollama-api gives an apples-to-apples
#                     cross-backend comparison against --backend mlx (same
#                     request shape, same reasoning-suppression knob on
#                     both sides). No-op when --backend mlx.
# --reps N            (default 1) repeats every task N times in the same file,
#                     each block prefixed with `===== <task_id> rep <i> =====`.
#                     Lets a downstream scorer compute mean ± stdev per cell.
# --t3-snapshot DATE  (default 2026-04-28) selects which dated T3 fixture
#                     under experiments/fixtures/task-3-merge-patterns-<DATE>.txt
#                     to use. T1 and T2 fixtures are stable across baselines.
# --t4-snapshot DATE  (default 2026-05-11) selects which dated T4 fixture
#                     under experiments/fixtures/task-4-commit-message-<DATE>.txt
#                     to use. T4 benchmarks the commit-message recipe against
#                     structural checks (subject length, conventional-commit
#                     prefix, no (#NN) suffix, flush-left body, no bullets,
#                     no participial-padding tails).
# --t5-snapshot DATE  (default 2026-05-11) selects which dated T5 fixture
#                     under experiments/fixtures/task-5-json-shape-<DATE>.txt
#                     to use. T5 benchmarks structured-extraction-into-JSON
#                     against an explicit schema with owner-filter rules.
# --t6-snapshot DATE  (default 2026-05-11) selects which dated T6 fixture
#                     under experiments/fixtures/task-6-regex-generation-<DATE>.txt
#                     to use. T6 benchmarks regex-generation-from-description
#                     against positive/negative acceptance tests.
#
# Output: writes experiments/results/raw/<model-slug>.txt
# Header: MODEL, BACKEND, DATE, REPS, T3_SNAPSHOT, T4_SNAPSHOT, T5_SNAPSHOT, T6_SNAPSHOT for reproducibility.

set -euo pipefail

reps=1
backend="ollama"
ollama_api=0
t3_snapshot="2026-04-28"
t4_snapshot="2026-05-11"
t5_snapshot="2026-05-11"
t6_snapshot="2026-05-11"

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --backend)
      backend="${2:-}"
      case "$backend" in
        ollama|mlx) ;;
        *) echo "--backend requires ollama|mlx, got '$backend'" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --ollama-api)
      ollama_api=1
      shift
      ;;
    --reps)
      reps="${2:-}"
      [[ "$reps" =~ ^[1-9][0-9]*$ ]] || { echo "--reps requires a positive integer" >&2; exit 2; }
      shift 2
      ;;
    --t3-snapshot)
      t3_snapshot="${2:-}"
      [[ -n "$t3_snapshot" ]] || { echo "--t3-snapshot requires a date" >&2; exit 2; }
      shift 2
      ;;
    --t4-snapshot)
      t4_snapshot="${2:-}"
      [[ -n "$t4_snapshot" ]] || { echo "--t4-snapshot requires a date" >&2; exit 2; }
      shift 2
      ;;
    --t5-snapshot)
      t5_snapshot="${2:-}"
      [[ -n "$t5_snapshot" ]] || { echo "--t5-snapshot requires a date" >&2; exit 2; }
      shift 2
      ;;
    --t6-snapshot)
      t6_snapshot="${2:-}"
      [[ -n "$t6_snapshot" ]] || { echo "--t6-snapshot requires a date" >&2; exit 2; }
      shift 2
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

model="${1:-}"
if [[ -z "$model" ]]; then
  echo "usage: runner.sh [--backend ollama|mlx] [--ollama-api] [--reps N] [--t3-snapshot DATE] <model-name>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$repo_root/experiments/fixtures"
out_dir="$repo_root/experiments/results/raw"
mkdir -p "$out_dir"

t3_fixture="$fixtures/task-3-merge-patterns-${t3_snapshot}.txt"
if [[ ! -f "$t3_fixture" ]]; then
  echo "T3 snapshot not found: $t3_fixture" >&2
  echo "available snapshots:" >&2
  ls "$fixtures"/task-3-merge-patterns-*.txt 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

t4_fixture="$fixtures/task-4-commit-message-${t4_snapshot}.txt"
if [[ ! -f "$t4_fixture" ]]; then
  echo "T4 snapshot not found: $t4_fixture" >&2
  echo "available snapshots:" >&2
  ls "$fixtures"/task-4-commit-message-*.txt 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

t5_fixture="$fixtures/task-5-json-shape-${t5_snapshot}.txt"
if [[ ! -f "$t5_fixture" ]]; then
  echo "T5 snapshot not found: $t5_fixture" >&2
  echo "available snapshots:" >&2
  ls "$fixtures"/task-5-json-shape-*.txt 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

t6_fixture="$fixtures/task-6-regex-generation-${t6_snapshot}.txt"
if [[ ! -f "$t6_fixture" ]]; then
  echo "T6 snapshot not found: $t6_fixture" >&2
  echo "available snapshots:" >&2
  ls "$fixtures"/task-6-regex-generation-*.txt 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

slug="$(echo "$model" | tr '/:.' '___')"
out="$out_dir/$slug.txt"

run_task_api() {
  # Posts the (fixture || directive) input to the backend's instruction
  # endpoint with reasoning disabled and temperature:0 — mirrors how
  # scripts/delegate.sh routes recipes in production. Required for T4–T6
  # because reasoning-capable models (qwen3.6, deepseek-r1) leak chain-of-
  # thought into structural-check outputs (commit-message rubric, JSON
  # parseability, single-line regex) when the CLI path is taken. The same
  # helper handles both backends since the wire shape is the only difference.
  local task_id="$1"
  local fixture="$2"
  local directive="$3"
  local rep="$4"

  echo "===== $task_id rep $rep =====" >> "$out"
  local start
  start=$(date +%s)

  local full_input
  full_input="$(cat "$fixture")"$'\n\n'"$directive"
  local response status=0 body
  if [[ "$backend" == "ollama" ]]; then
    local host="${OLLAMA_HOST:-http://localhost:11434}"
    local payload
    payload=$(jq -nc --arg m "$model" --arg p "$full_input" \
      '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}')
    response=$(curl -sS --fail -X POST "$host/api/generate" -d @- <<<"$payload") || status=$?
    if (( status == 0 )); then
      body=$(jq -r '.response // ""' <<<"$response")
    else
      body="API_CALL_FAILED status=$status"
    fi
  else
    # MLX: chat-completions with chat_template_kwargs.enable_thinking:false.
    # /v1/completions is the raw-prompt endpoint and bypasses the chat
    # template — instruction-tuned models emit whitespace there. See
    # ROADMAP MLX backend track 2026-05-12 for the empirical write-up.
    local host="${MLX_HOST:-http://localhost:8080}"
    local max_tokens="${DELEGATE_MAX_TOKENS:-4096}"
    local payload
    payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson mt "$max_tokens" \
      '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:0, max_tokens:$mt, chat_template_kwargs:{enable_thinking:false}}')
    response=$(curl -sS --fail -X POST "$host/v1/chat/completions" -d @- <<<"$payload") || status=$?
    if (( status == 0 )); then
      body=$(jq -r '.choices[0].message.content // ""' <<<"$response")
    else
      body="API_CALL_FAILED status=$status"
    fi
  fi
  local end
  end=$(date +%s)
  local elapsed=$((end - start))
  echo "DURATION_SEC: $elapsed" >> "$out"
  echo "RUN_STATUS: $status" >> "$out"
  if (( status != 0 )); then
    echo "RUN_FAILED: curl exited $status" >> "$out"
  fi
  echo "OUTPUT:" >> "$out"
  echo "$body" >> "$out"
  echo "" >> "$out"
}

run_task() {
  # T1–T3 historically used the `ollama run` CLI path for backwards-
  # compatibility with the 2026-04-28 baseline. The MLX backend has no CLI
  # equivalent, so when backend=mlx we route through run_task_api instead;
  # the prompt arg becomes the trailing directive concatenated to the
  # fixture body, matching the chat-completions semantics. The --ollama-api
  # flag opts Ollama into the same API + think:false regime so a cross-
  # backend comparison is apples-to-apples (the CLI path leaks reasoning
  # tokens and inflates T1–T3 latency by ~30×; see ROADMAP MLX track for
  # the 2026-05-12 baseline notes).
  if [[ "$backend" == "mlx" ]] || (( ollama_api )); then
    run_task_api "$@"
    return
  fi
  local task_id="$1"
  local fixture="$2"
  local prompt="$3"
  local rep="$4"

  echo "===== $task_id rep $rep =====" >> "$out"
  local start
  start=$(date +%s)
  # Run ollama, strip ANSI/cursor noise and the spinner braille bytes, then
  # drop the leading blank-line block the spinner left behind (awk: skip until
  # first non-empty line, then print everything). Track the pipeline status
  # via `|| run_status=$?` — set -e plus pipefail mean a bare PIPESTATUS check
  # would never run, and PIPESTATUS doesn't see inside command substitutions
  # anyway. With pipefail enabled, $? on the substitution is the failed step's
  # exit code if any element in the pipeline failed.
  local body run_status=0
  body=$(ollama run "$model" "$prompt" < "$fixture" 2>&1 \
    | perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/\e\[\?[0-9]+[lh]//g; s/\r//g; s/\xe2\xa0[\x80-\xbf]//g' \
    | awk 'NF || seen { seen=1; print }') || run_status=$?
  local end
  end=$(date +%s)
  local elapsed=$((end - start))
  echo "DURATION_SEC: $elapsed" >> "$out"
  echo "RUN_STATUS: $run_status" >> "$out"
  if (( run_status != 0 )); then
    echo "RUN_FAILED: ollama exited $run_status" >> "$out"
  fi
  echo "OUTPUT:" >> "$out"
  echo "$body" >> "$out"
  echo "" >> "$out"
}

: > "$out"
echo "MODEL: $model" >> "$out"
echo "BACKEND: $backend" >> "$out"
echo "OLLAMA_API: $ollama_api" >> "$out"
echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out"
echo "REPS: $reps" >> "$out"
echo "T3_SNAPSHOT: $t3_snapshot" >> "$out"
echo "T4_SNAPSHOT: $t4_snapshot" >> "$out"
echo "T5_SNAPSHOT: $t5_snapshot" >> "$out"
echo "T6_SNAPSHOT: $t6_snapshot" >> "$out"
echo "" >> "$out"

for (( rep=1; rep<=reps; rep++ )); do
  # T1: doc-drift verification — structured compare with verdicts
  run_task "T1-doc-drift" "$fixtures/task-1-doc-drift.txt" \
    "You are auditing a roadmap against codebase evidence. The fixture lists 4 claims (A/B/C/D) and the actual file evidence. For each claim output one line in this exact format: CLAIM_X: <already-done|still-open> — <one-line evidence reference>. No preamble, no commentary, no chain of thought, just four lines." \
    "$rep"

  # T2: party-config structural variance — should be CLEAN
  run_task "T2-party-config" "$fixtures/task-2-party-config.txt" \
    "These are 6 political party YAML configs. Expected shape: top-level keys id, name, positions, stances, quotes; positions has 8 numeric keys (independence, nhs, housing, climate, tax, economy, education, equality) each 0-2; stances and quotes each have the same 8 keys with text values. Output exactly one of: CLEAN  OR  INCONSISTENT followed by one bullet per actual deviation. Do not invent issues. No preamble." \
    "$rep"

  # T3: open-ended pattern review — known to invite hallucination
  run_task "T3-merge-patterns" "$t3_fixture" \
    "These are the last 10 commits on a Scottish election website. List up to 4 specific concerns or loose ends each tied to a checkable file/path/grep pattern. For each: CONCERN | FILE_OR_PATTERN_TO_VERIFY. If nothing is reliably checkable, output: NONE. Do not speculate beyond what the commit subjects state." \
    "$rep"

  # T4: commit-message recipe — structural-check benchmark for the
  # prompts/commit-message.md recipe. The fixture IS the substituted recipe
  # prompt; the model's job is to follow the directives despite the visible
  # (#NN) suffix and padding patterns in the recent-commit anchors.
  # Uses run_task_api (HTTP /api/generate with think:false) so the
  # measurement reflects how delegate.sh routes the recipe in production.
  run_task_api "T4-commit-message" "$t4_fixture" \
    "Follow the instructions in the message above. Match the example commit messages exactly in shape and tone." \
    "$rep"

  # T5: structured-extraction-into-JSON — schema-conformance benchmark.
  # The fixture carries the directive, the schema, the owner-filter rules,
  # and the source email; the model's job is to emit ONLY the JSON object
  # with the three Ismael items at YYYY-MM-DD dates. Uses run_task_api
  # so think:false suppresses chain-of-thought that would otherwise wrap
  # the JSON in commentary and break parseability.
  run_task_api "T5-json-shape" "$t5_fixture" \
    "Follow the instructions in the message above. Output ONLY the JSON object, no preamble or markdown fence." \
    "$rep"

  # T6: regex-generation — pattern-from-description benchmark with
  # explicit positive/negative acceptance tests. The fixture spells out
  # the task, the matching set, and the rejecting set; the model's job
  # is to emit ONE line containing only the regex pattern. Uses
  # run_task_api so think:false suppresses chain-of-thought that would
  # otherwise produce explanation paragraphs surrounding the regex and
  # break pattern extraction.
  run_task_api "T6-regex-generation" "$t6_fixture" \
    "Follow the instructions in the message above. Output ONLY the regex pattern on a single line. No fence, no slashes, no commentary." \
    "$rep"
done

echo "Done: $out"
