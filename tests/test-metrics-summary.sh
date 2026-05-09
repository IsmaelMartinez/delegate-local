#!/usr/bin/env bash
# Unit tests for scripts/metrics-summary.sh using a fixture JSONL.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/metrics-summary.sh"

pass=0
fail=0
assert_eq() {
  local e="$1" a="$2" n="$3"
  if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1))
  else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}

# 1. Missing file -> exit 1.
EC=0
out=$(bash "$SCRIPT" --file /nonexistent/path.jsonl 2>&1) || EC=$?
assert_eq 1 "$EC" "missing file -> exit 1"

# 2. Empty file -> exit 0 with note.
empty=$(mktemp); : > "$empty"
EC=0
out=$(bash "$SCRIPT" --file "$empty" 2>&1) || EC=$?
assert_eq 0 "$EC" "empty file -> exit 0"
assert_contains "empty" "$out" "empty file message"
rm -f "$empty"

# 3. Fixture: 4 invocations across 2 tiers, 2 models. Verify the summary
# reports the right counts, time range, and tokens-avoided sum.
fixture=$(mktemp)
cat > "$fixture" <<'EOF'
{"ts":"2026-04-29T08:00:00Z","tier":"prose","model":"qwen3.6:35b-a3b","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-04-29T08:30:00Z","tier":"prose","model":"qwen3.6:35b-a3b","prompt_chars":50,"context_chars":150,"output_chars":300,"duration_ms":5100,"exit_status":0,"estimated_tokens_avoided":125}
{"ts":"2026-04-29T09:00:00Z","tier":"reasoning","model":"phi4-reasoning:plus","prompt_chars":30,"context_chars":120,"output_chars":250,"duration_ms":2800,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-04-29T09:15:00Z","tier":"reasoning","model":"phi4-reasoning:plus","prompt_chars":35,"context_chars":140,"output_chars":225,"duration_ms":3500,"exit_status":1,"estimated_tokens_avoided":100}
EOF

EC=0
out=$(bash "$SCRIPT" --file "$fixture" 2>&1) || EC=$?
assert_eq 0 "$EC" "fixture: exits 0"
assert_contains "Total invocations:   4" "$out" "fixture: total count"
assert_contains "Errors (non-zero):   1" "$out" "fixture: error count"
assert_contains "Tokens avoided (≈):  425" "$out" "fixture: tokens avoided sum"
assert_contains "2026-04-29T08:00:00Z" "$out" "fixture: first ts"
assert_contains "2026-04-29T09:15:00Z" "$out" "fixture: last ts"
assert_contains "prose" "$out" "fixture: prose tier appears"
assert_contains "reasoning" "$out" "fixture: reasoning tier appears"
assert_contains "qwen3.6:35b-a3b" "$out" "fixture: top model appears"
assert_contains "phi4-reasoning:plus" "$out" "fixture: second model appears"
# Lines without a source field count as delegate for backward compatibility.
assert_contains "delegate=4" "$out" "fixture: source-less entries count as delegate"
assert_contains "experiment=0" "$out" "fixture: no experiment entries here"
rm -f "$fixture"

# 4. Mixed-source fixture: delegate + experiment lines together. Verify the
# summary splits them out and shows per-session rollup for experiment rows.
mixed=$(mktemp)
cat > "$mixed" <<'EOF'
{"ts":"2026-05-04T08:00:00Z","source":"delegate","tier":"prose","model":"qwen3.6:35b-a3b","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-04T09:00:00Z","source":"experiment","session":"2026-05-04-code-delegation-probe","model":"deepseek-r1:32b","prompt_tokens":500,"eval_tokens":80,"duration_ms":4500,"output_bytes":349,"exit_status":0,"estimated_tokens_avoided":580}
{"ts":"2026-05-04T09:05:00Z","source":"experiment","session":"2026-05-04-code-delegation-probe","model":"qwen3-coder-next:latest","prompt_tokens":500,"eval_tokens":60,"duration_ms":3100,"output_bytes":302,"exit_status":0,"estimated_tokens_avoided":560}
EOF

EC=0
out=$(bash "$SCRIPT" --file "$mixed" 2>&1) || EC=$?
assert_eq 0 "$EC" "mixed: exits 0"
assert_contains "Total invocations:   3" "$out" "mixed: total count"
assert_contains "delegate=1" "$out" "mixed: one delegate entry"
assert_contains "experiment=2" "$out" "mixed: two experiment entries"
assert_contains "Tokens avoided (≈):  1240" "$out" "mixed: tokens avoided sum across sources"
assert_contains "Per-source:" "$out" "mixed: per-source header present"
assert_contains "Per-session (experiment):" "$out" "mixed: per-session header present"
assert_contains "2026-05-04-code-delegation-probe" "$out" "mixed: session label appears"
assert_contains "Per-tier (delegate):" "$out" "mixed: per-tier header present for delegate rows"
rm -f "$mixed"

# 5. Feedback rollup: delegate events with hit/miss/untracked feedback rows.
# Verifies that miss (kept:false) is counted, not silently dropped by the
# jq // alternative-operator quirk.
fb=$(mktemp)
cat > "$fb" <<'EOF'
{"ts":"2026-05-09T10:00:00Z","source":"delegate","tier":"prose","model":"q","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-09T10:30:00Z","source":"delegate","tier":"prose","model":"q","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4500,"exit_status":0,"estimated_tokens_avoided":120}
{"ts":"2026-05-09T11:00:00Z","source":"delegate","tier":"reasoning","model":"d","prompt_chars":50,"context_chars":200,"output_chars":250,"duration_ms":7000,"exit_status":0,"estimated_tokens_avoided":150}
{"ts":"2026-05-09T11:30:00Z","source":"delegate","tier":"reasoning","model":"d","prompt_chars":50,"context_chars":200,"output_chars":250,"duration_ms":7200,"exit_status":0,"estimated_tokens_avoided":160}
{"ts":"2026-05-09T20:00:00Z","source":"feedback","ref_ts":"2026-05-09T10:00:00Z","kept":true}
{"ts":"2026-05-09T20:01:00Z","source":"feedback","ref_ts":"2026-05-09T10:30:00Z","kept":false,"reason":"bullets"}
{"ts":"2026-05-09T20:02:00Z","source":"feedback","ref_ts":"2026-05-09T11:00:00Z","kept":false}
EOF

EC=0
out=$(bash "$SCRIPT" --file "$fb" 2>&1) || EC=$?
assert_eq 0 "$EC" "feedback: exits 0"
# Only delegate calls counted in invocations; feedback rows are zero-cost.
assert_contains "delegate=4" "$out" "feedback: 4 delegate invocations counted"
assert_contains "Delegation feedback (hit/miss):" "$out" "feedback: section header"
assert_contains "prose" "$out" "feedback: prose row appears"
assert_contains "reasoning" "$out" "feedback: reasoning row appears"
# Specific counts: prose has 1 hit + 1 miss + 0 untracked.
assert_contains "prose           n=2  hits=1  misses=1  untracked=0" "$out" "feedback: prose hit/miss exact counts"
# Reasoning has 1 miss + 1 untracked (no feedback for the second reasoning call).
assert_contains "reasoning       n=2  hits=0  misses=1  untracked=1" "$out" "feedback: reasoning miss not silently dropped"
# Feedback rows must NOT inflate Tokens avoided (they have no token field).
# Sum of delegate-only tokens: 100+120+150+160 = 530.
assert_contains "Tokens avoided (≈):  530" "$out" "feedback: tokens not inflated by feedback rows"
rm -f "$fb"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
