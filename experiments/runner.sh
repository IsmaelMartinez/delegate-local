#!/usr/bin/env bash
# Run the 3 fixture tasks against a single Ollama model and emit timing + output.
# Usage: bash runner.sh <model-name>
# Output: writes experiments/results/raw/<model-slug>.txt

set -euo pipefail

model="${1:-}"
if [[ -z "$model" ]]; then
  echo "usage: runner.sh <model-name>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$repo_root/experiments/fixtures"
out_dir="$repo_root/experiments/results/raw"
mkdir -p "$out_dir"

slug="$(echo "$model" | tr '/:.' '___')"
out="$out_dir/$slug.txt"

run_task() {
  local task_id="$1"
  local fixture="$2"
  local prompt="$3"

  echo "===== $task_id =====" >> "$out"
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
echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out"
echo "" >> "$out"

# T1: doc-drift verification — structured compare with verdicts
run_task "T1-doc-drift" "$fixtures/task-1-doc-drift.txt" \
  "You are auditing a roadmap against codebase evidence. The fixture lists 4 claims (A/B/C/D) and the actual file evidence. For each claim output one line in this exact format: CLAIM_X: <already-done|still-open> — <one-line evidence reference>. No preamble, no commentary, no chain of thought, just four lines."

# T2: party-config structural variance — should be CLEAN
run_task "T2-party-config" "$fixtures/task-2-party-config.txt" \
  "These are 6 political party YAML configs. Expected shape: top-level keys id, name, positions, stances, quotes; positions has 8 numeric keys (independence, nhs, housing, climate, tax, economy, education, equality) each 0-2; stances and quotes each have the same 8 keys with text values. Output exactly one of: CLEAN  OR  INCONSISTENT followed by one bullet per actual deviation. Do not invent issues. No preamble."

# T3: open-ended pattern review — known to invite hallucination
run_task "T3-merge-patterns" "$fixtures/task-3-merge-patterns.txt" \
  "These are the last 10 commits on a Scottish election website. List up to 4 specific concerns or loose ends each tied to a checkable file/path/grep pattern. For each: CONCERN | FILE_OR_PATTERN_TO_VERIFY. If nothing is reliably checkable, output: NONE. Do not speculate beyond what the commit subjects state."

echo "Done: $out"
