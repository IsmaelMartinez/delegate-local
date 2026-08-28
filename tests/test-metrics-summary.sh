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
{"ts":"2026-05-09T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-09T10:30:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","prompt_chars":40,"context_chars":160,"output_chars":200,"duration_ms":4500,"exit_status":0,"estimated_tokens_avoided":120}
{"ts":"2026-05-09T11:00:00Z","source":"delegate","recipe":"summarise-issue","tier":"reasoning","model":"d","prompt_chars":50,"context_chars":200,"output_chars":250,"duration_ms":7000,"exit_status":0,"estimated_tokens_avoided":150}
{"ts":"2026-05-09T11:30:00Z","source":"delegate","recipe":"summarise-issue","tier":"reasoning","model":"d","prompt_chars":50,"context_chars":200,"output_chars":250,"duration_ms":7200,"exit_status":0,"estimated_tokens_avoided":160}
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
# Recipe-scoped coverage headline: 4 recipe delegations, 3 with feedback = 75%.
assert_contains "coverage=75%" "$out" "feedback: recipe verdict coverage headline (recipe-scoped)"
# Feedback rows must NOT inflate Tokens avoided (they have no token field).
# Sum of delegate-only tokens: 100+120+150+160 = 530.
assert_contains "Tokens avoided (≈):  530" "$out" "feedback: tokens not inflated by feedback rows"
rm -f "$fb"

# 5b. Failed delegations (exit_status != 0) are excluded from the coverage
# denominator: a canary-timeout (exit 3) produced no output, so it cannot carry a
# hit/miss verdict and must not count as "untracked". Fixture: one successful
# recipe delegation with a hit, plus one failed (exit 3) recipe delegation with
# no verdict. Coverage must be 100% (1/1), not 50% (1/2).
fbx=$(mktemp)
cat > "$fbx" <<'EOF'
{"ts":"2026-06-15T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-15T10:05:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":50,"exit_status":3,"estimated_tokens_avoided":0}
{"ts":"2026-06-15T20:00:00Z","source":"feedback","ref_ts":"2026-06-15T10:00:00Z","kept":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$fbx" 2>&1) || EC=$?
assert_eq 0 "$EC" "failed-excluded: exits 0"
assert_contains "Recipe delegations (calibration signal): n=1  hits=1  misses=0  untracked=0" "$out" "failed-excluded: exit!=0 recipe row dropped from calibration n"
assert_contains "coverage=100%" "$out" "failed-excluded: coverage over successful delegations only (not 50%)"
rm -f "$fbx"

# 6. Latest-feedback-wins: two feedback rows for the same delegate, recorded
# in chronological order (hit, then miss). The later miss should win — the
# user revised their verdict — and be counted as the miss.
revised=$(mktemp)
cat > "$revised" <<'EOF'
{"ts":"2026-05-09T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":50}
{"ts":"2026-05-09T20:00:00Z","source":"feedback","ref_ts":"2026-05-09T10:00:00Z","kept":true}
{"ts":"2026-05-09T20:05:00Z","source":"feedback","ref_ts":"2026-05-09T10:00:00Z","kept":false,"reason":"second look — not actually used"}
EOF

EC=0
out=$(bash "$SCRIPT" --file "$revised" 2>&1) || EC=$?
assert_eq 0 "$EC" "revised: exits 0"
assert_contains "prose           n=1  hits=0  misses=1  untracked=0" "$out" "revised: latest feedback wins (miss overrides earlier hit)"
rm -f "$revised"

# 7. Per-backend section: only shown when 2+ distinct backends appear.
# Single-backend fixture (only ollama-tagged rows) -> no Per-backend section.
single=$(mktemp)
cat > "$single" <<'EOF'
{"ts":"2026-05-12T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-12T10:05:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4500,"exit_status":0,"estimated_tokens_avoided":110}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$single" 2>&1) || EC=$?
assert_eq 0 "$EC" "single-backend: exits 0"
case "$out" in
  *"Per-backend"*) echo "  FAIL  single-backend: Per-backend section should be hidden"; fail=$((fail+1));;
  *) echo "  PASS  single-backend: Per-backend section hidden when only one backend"; pass=$((pass+1));;
esac
rm -f "$single"

# 8. Mixed-backend fixture: rows from both ollama and mlx -> Per-backend
# section appears with per-backend n/tokens/p50/p95.
mixed=$(mktemp)
cat > "$mixed" <<'EOF'
{"ts":"2026-05-12T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-12T10:05:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4500,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-05-12T10:10:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"mlx-community/Qwen3.6-35B-A3B-Instruct-8bit","duration_ms":3200,"exit_status":0,"estimated_tokens_avoided":105}
{"ts":"2026-05-12T10:15:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"mlx-community/Qwen3.6-35B-A3B-Instruct-8bit","duration_ms":3400,"exit_status":0,"estimated_tokens_avoided":115}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$mixed" 2>&1) || EC=$?
assert_eq 0 "$EC" "mixed-backend: exits 0"
assert_contains "Per-backend (delegate):" "$out" "mixed-backend: section header present"
assert_contains "ollama" "$out" "mixed-backend: ollama row present"
assert_contains "mlx" "$out" "mixed-backend: mlx row present"
rm -f "$mixed"

# 9. Back-compat: rows missing the backend field (pre-2026-05) are bucketed
# as 'ollama'. Combined with an mlx row, the Per-backend section should
# show both with the unset rows counted under ollama.
backcompat=$(mktemp)
cat > "$backcompat" <<'EOF'
{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-04-29T08:30:00Z","source":"delegate","tier":"prose","model":"qwen3.6:35b-a3b","duration_ms":4500,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-05-12T10:10:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"mlx-community/Qwen3.6-35B-A3B-Instruct-8bit","duration_ms":3200,"exit_status":0,"estimated_tokens_avoided":105}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$backcompat" 2>&1) || EC=$?
assert_eq 0 "$EC" "back-compat: exits 0"
assert_contains "Per-backend (delegate):" "$out" "back-compat: section header present"
# The two pre-backend rows should land under ollama (n=2 with tokens=210),
# and the single mlx row stays under mlx (n=1).
assert_contains "ollama" "$out" "back-compat: pre-2026-05 rows bucketed under ollama"
assert_contains "n=2" "$out" "back-compat: ollama bucket gets the 2 unset-backend rows"
assert_contains "n=1" "$out" "back-compat: mlx bucket gets its single row"
rm -f "$backcompat"

# 10. Per-backend section is robust to missing estimated_tokens_avoided and
# duration_ms fields. The gemini-code-assist PR #106 review flagged that
# without // 0 defaults, an MLX bucket containing only rows with absent
# fields would render "tokens≈null  p50=nullms  p95=nullms". The defaults
# make sure the line stays numeric.
sparse=$(mktemp)
cat > "$sparse" <<'EOF'
{"ts":"2026-05-12T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-12T10:05:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"m"}
{"ts":"2026-05-12T10:10:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"m"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$sparse" 2>&1) || EC=$?
assert_eq 0 "$EC" "sparse: exits 0"
# Extract only the Per-backend section's body so the assertion is scoped to
# the new code introduced in this PR. (Per-tier and Per-source have the same
# null-leak class but are pre-existing and out of scope here — fix when
# evidence demands it, not speculatively.)
per_backend=$(echo "$out" | awk '/^Per-backend \(delegate\):/{flag=1; next} /^$/{flag=0} flag')
case "$per_backend" in
  *"null"*) echo "  FAIL  sparse: 'null' leaked into Per-backend output ($per_backend)"; fail=$((fail+1));;
  *) echo "  PASS  sparse: no 'null' in Per-backend output"; pass=$((pass+1));;
esac
assert_contains "tokens≈0" "$per_backend" "sparse: missing tokens default to 0 in Per-backend"
assert_contains "p50=0ms" "$per_backend" "sparse: missing duration_ms defaults to 0 in Per-backend p50"
rm -f "$sparse"

# 11. Per-project section: 2+ distinct projects -> section printed with
# correct hits/misses/untracked (mirroring the feedback join) and p50 latency.
# Project "alpha": 2 calls, 1 hit + 1 miss. Project "beta": 1 call, untracked.
multiproj=$(mktemp)
cat > "$multiproj" <<'EOF'
{"ts":"2026-05-25T10:00:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-25T10:05:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-05-25T10:10:00Z","source":"delegate","project":"beta","tier":"reasoning","model":"d","duration_ms":6000,"exit_status":0,"estimated_tokens_avoided":150}
{"ts":"2026-05-25T20:00:00Z","source":"feedback","ref_ts":"2026-05-25T10:00:00Z","kept":true}
{"ts":"2026-05-25T20:01:00Z","source":"feedback","ref_ts":"2026-05-25T10:05:00Z","kept":false,"reason":"bullets"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$multiproj" 2>&1) || EC=$?
assert_eq 0 "$EC" "per-project: exits 0"
assert_contains "Per-project (delegate):" "$out" "per-project: section header present"
assert_contains "alpha                 n=2  hits=1  misses=1  untracked=0  p50=4200ms" "$out" "per-project: alpha hit/miss exact counts"
assert_contains "beta                  n=1  hits=0  misses=0  untracked=1  p50=6000ms" "$out" "per-project: beta untracked when no feedback"
rm -f "$multiproj"

# 12. Per-project negative gate: single distinct project -> section hidden.
# Also covers rows missing the project field bucketing to "(none)" (still one
# distinct value, so still hidden).
singleproj=$(mktemp)
cat > "$singleproj" <<'EOF'
{"ts":"2026-05-25T10:00:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-25T10:05:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":110}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$singleproj" 2>&1) || EC=$?
assert_eq 0 "$EC" "single-project: exits 0"
case "$out" in
  *"Per-project"*) echo "  FAIL  single-project: Per-project section should be hidden"; fail=$((fail+1));;
  *) echo "  PASS  single-project: Per-project section hidden when only one project"; pass=$((pass+1));;
esac
rm -f "$singleproj"

# 13. Per-recipe section: delegate rows carrying a recipe field -> section
# printed grouped by recipe with hit/miss/untracked. commit-message: 2 calls,
# 1 hit + 1 untracked. summarise-issue: 1 call, 1 miss.
recipefix=$(mktemp)
cat > "$recipefix" <<'EOF'
{"ts":"2026-05-26T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-26T10:05:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-05-26T10:10:00Z","source":"delegate","recipe":"summarise-issue","tier":"prose","model":"q","duration_ms":3800,"exit_status":0,"estimated_tokens_avoided":90}
{"ts":"2026-05-26T10:15:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":3900,"exit_status":0,"estimated_tokens_avoided":80}
{"ts":"2026-05-26T20:00:00Z","source":"feedback","ref_ts":"2026-05-26T10:00:00Z","kept":true}
{"ts":"2026-05-26T20:01:00Z","source":"feedback","ref_ts":"2026-05-26T10:10:00Z","kept":false,"reason":"missed a comment"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$recipefix" 2>&1) || EC=$?
assert_eq 0 "$EC" "per-recipe: exits 0"
assert_contains "Per-recipe (delegate):" "$out" "per-recipe: section header present"
assert_contains "commit-message        n=2  hits=1  misses=0  untracked=1" "$out" "per-recipe: commit-message hit/untracked exact counts"
assert_contains "summarise-issue       n=1  hits=0  misses=1  untracked=0" "$out" "per-recipe: summarise-issue miss not dropped"
rm -f "$recipefix"

# 14. Per-recipe negative gate: no recipe rows -> section hidden.
norecipe=$(mktemp)
cat > "$norecipe" <<'EOF'
{"ts":"2026-05-26T10:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-26T10:05:00Z","source":"delegate","tier":"reasoning","model":"d","duration_ms":6000,"exit_status":0,"estimated_tokens_avoided":150}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$norecipe" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-recipe: exits 0"
case "$out" in
  *"Per-recipe"*) echo "  FAIL  no-recipe: Per-recipe section should be hidden"; fail=$((fail+1));;
  *) echo "  PASS  no-recipe: Per-recipe section hidden when no recipe rows"; pass=$((pass+1));;
esac
rm -f "$norecipe"

# 15. Verdict coverage is scoped to recipe delegations; raw / no-recipe calls
# (ad-hoc + benchmark/audit traffic) are reported separately and do NOT inflate
# the recipe untracked count. 2 recipe calls (1 tracked) + 2 raw calls (1 tracked).
denoise=$(mktemp)
cat > "$denoise" <<'EOF'
{"ts":"2026-05-27T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-27T10:05:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-05-27T10:10:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":900,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-27T10:15:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":950,"exit_status":0,"estimated_tokens_avoided":45}
{"ts":"2026-05-27T20:00:00Z","source":"feedback","ref_ts":"2026-05-27T10:00:00Z","kept":true}
{"ts":"2026-05-27T20:01:00Z","source":"feedback","ref_ts":"2026-05-27T10:10:00Z","kept":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$denoise" 2>&1) || EC=$?
assert_eq 0 "$EC" "denoise: exits 0"
assert_contains "Recipe delegations (calibration signal): n=2  hits=1  misses=0  untracked=1" "$out" "denoise: recipe untracked NOT inflated by raw calls"
assert_contains "coverage=50%" "$out" "denoise: coverage scoped to recipe delegations"
assert_contains "Raw / no-recipe" "$out" "denoise: raw/no-recipe line present"
assert_contains "n=2  tracked=1  untracked=1" "$out" "denoise: raw calls bucketed separately, not in recipe untracked"
rm -f "$denoise"

# 12. Trigger rate (#277): source:"opportunity" rows (from the delegate-boundary
# hook) drive a per-project trigger-rate section and must NOT be counted as
# invocations or errors — they carry no exit_status, so before the call-filter
# guard they would have inflated the error count. Fixture: project "alpha" has 2
# boundaries (1 delegated), "beta" has 1 boundary (missed).
opp=$(mktemp)
cat > "$opp" <<'EOF'
{"ts":"2026-06-08T10:00:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-08T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true}
{"ts":"2026-06-08T10:30:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false}
{"ts":"2026-06-08T11:00:00Z","source":"opportunity","project":"beta","boundary":"pr-create","suggested_recipe":"pr-description","delegated":false}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$opp" 2>&1) || EC=$?
assert_eq 0 "$EC" "trigger-rate: exits 0"
assert_contains "delegate=1" "$out" "trigger-rate: only the delegate row counts as an invocation"
assert_contains "Errors (non-zero):   0" "$out" "trigger-rate: opportunity rows not miscounted as errors"
assert_contains "Trigger rate (commit/PR/release/comment boundaries):" "$out" "trigger-rate: section header present"
assert_contains "alpha" "$out" "trigger-rate: alpha project listed"
assert_contains "beta" "$out" "trigger-rate: beta project listed"
assert_contains "opportunities=2  delegated=1  missed=1  rate=50%" "$out" "trigger-rate: alpha 50% (2 opps, 1 delegated)"
assert_contains "opportunities=1  delegated=0  missed=1  rate=0%" "$out" "trigger-rate: beta 0% (1 opp, missed)"
# Opportunity rows must not leak into the Per-source model/latency rollup.
case "$out" in
  *"opportunity     n="*) echo "  FAIL  trigger-rate: opportunity must not appear as a Per-source call row"; fail=$((fail+1));;
  *) echo "  PASS  trigger-rate: opportunity excluded from Per-source rollup"; pass=$((pass+1));;
esac
rm -f "$opp"

# 12b. state:"pre-drafted" opportunity rows (#349) are a --body-file post of text
# authored at an earlier Write, so the drafting moment was never at that Bash
# call. They must leave the trigger rate alone — out of the numerator AND the
# denominator — and be surfaced as their own count. Fixture: alpha has the same
# 1-delegated / 1-missed pair as above plus 2 pre-drafted posts, so a naive
# denominator would read 25% instead of the true 50%.
predraft=$(mktemp)
cat > "$predraft" <<'EOF'
{"ts":"2026-06-08T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true}
{"ts":"2026-06-08T10:30:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false}
{"ts":"2026-06-08T10:40:00Z","source":"opportunity","project":"alpha","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":false,"state":"pre-drafted"}
{"ts":"2026-06-08T10:45:00Z","source":"opportunity","project":"alpha","boundary":"issue-create","suggested_recipe":"github-issue-body","delegated":false,"state":"pre-drafted"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$predraft" 2>&1) || EC=$?
assert_eq 0 "$EC" "pre-drafted: exits 0"
assert_contains "opportunities=2  delegated=1  missed=1  rate=50%  pre-drafted=2" "$out" \
  "pre-drafted: excluded from the trigger-rate numerator and denominator, reported separately"
rm -f "$predraft"

# 16. Phase E agent-observed verdict tier. Fixture: 4 commit-message recipe
# delegations — D1 human HIT, D2 agent HIT (used), D3 agent MISS (rewrote),
# D4 untracked. The honesty property: the human hit-rate counts D1 only (NOT
# the agent HIT), while coverage and untracked count BOTH tiers, and a separate
# Agent-observed line reports the agent usage rate.
agenttier=$(mktemp)
cat > "$agenttier" <<'EOF'
{"ts":"2026-06-14T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-14T10:05:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4100,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-06-14T10:10:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":120}
{"ts":"2026-06-14T10:15:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4300,"exit_status":0,"estimated_tokens_avoided":130}
{"ts":"2026-06-14T20:00:00Z","source":"feedback","ref_ts":"2026-06-14T10:00:00Z","kept":true}
{"ts":"2026-06-14T20:01:00Z","source":"feedback","ref_ts":"2026-06-14T10:05:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-14T20:02:00Z","source":"feedback","ref_ts":"2026-06-14T10:10:00Z","kept":false,"verdict_source":"agent"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$agenttier" 2>&1) || EC=$?
assert_eq 0 "$EC" "agent-tier: exits 0"
# Honesty property: human hits=1 (NOT 2 — the agent HIT must not inflate it),
# agent column shows 2, untracked=1 (only D4), coverage=75% (3 of 4 covered).
assert_contains "Recipe delegations (calibration signal): n=4  hits=1  misses=0  agent=2  untracked=1  coverage=75%" "$out" "agent-tier: human hit-rate excludes agent verdicts; coverage+untracked count both"
# Dedicated agent-observed usage line.
assert_contains "Agent-observed (usage, not quality): n=2  used=1  rewrote=1  usage_rate=50%" "$out" "agent-tier: agent usage reported as its own figure"
# Per-recipe rollup gains the agent column.
assert_contains "commit-message" "$out" "agent-tier: per-recipe lists commit-message"
recipe_line=$(printf '%s\n' "$out" | grep -E "^  commit-message" | tail -1)
assert_contains "agent=2" "$recipe_line" "agent-tier: per-recipe row carries agent column"
rm -f "$agenttier"

# 16b. A delegation carrying BOTH a human and an agent verdict counts in both
# columns (never merged): the human HIT keeps the quality signal, the agent
# MISS shows in the agent column, and the delegation is covered (untracked=0).
bothtier=$(mktemp)
cat > "$bothtier" <<'EOF'
{"ts":"2026-06-14T11:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-14T21:00:00Z","source":"feedback","ref_ts":"2026-06-14T11:00:00Z","kept":true}
{"ts":"2026-06-14T21:01:00Z","source":"feedback","ref_ts":"2026-06-14T11:00:00Z","kept":false,"verdict_source":"agent"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$bothtier" 2>&1) || EC=$?
assert_eq 0 "$EC" "both-tier: exits 0"
assert_contains "Recipe delegations (calibration signal): n=1  hits=1  misses=0  agent=1  untracked=0  coverage=100%" "$out" "both-tier: human hit + agent verdict count in separate columns, delegation covered once"
rm -f "$bothtier"

# 16c. With NO agent verdicts, the agent column and the Agent-observed line are
# both absent — single-tier files print exactly as before.
noagent=$(mktemp)
cat > "$noagent" <<'EOF'
{"ts":"2026-06-14T12:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-14T22:00:00Z","source":"feedback","ref_ts":"2026-06-14T12:00:00Z","kept":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$noagent" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-agent: exits 0"
case "$out" in
  *"agent="*) echo "  FAIL  no-agent: agent column must be absent without agent verdicts"; fail=$((fail+1));;
  *) echo "  PASS  no-agent: agent column absent without agent verdicts"; pass=$((pass+1));;
esac
case "$out" in
  *"Agent-observed"*) echo "  FAIL  no-agent: Agent-observed line must be absent without agent verdicts"; fail=$((fail+1));;
  *) echo "  PASS  no-agent: Agent-observed line absent without agent verdicts"; pass=$((pass+1));;
esac
assert_contains "Recipe delegations (calibration signal): n=1  hits=1  misses=0  untracked=0  coverage=100%" "$out" "no-agent: legacy single-tier line shape unchanged"
rm -f "$noagent"

# 17. --since window: restricts every section to rows at or after the cutoff.
# Fixture spans three dates; --since 2026-06-15 keeps the last two.
windowfix=$(mktemp)
cat > "$windowfix" <<'EOF'
{"ts":"2026-01-01T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-15T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":200}
{"ts":"2026-06-16T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":300}
EOF
# Baseline (no window): all 3 rows.
out=$(bash "$SCRIPT" --file "$windowfix" 2>&1)
assert_contains "Total invocations:   3" "$out" "window: no flag -> all 3 rows"
case "$out" in *"Window:"*) echo "  FAIL  window: no Window line without a flag"; fail=$((fail+1));; *) echo "  PASS  window: no Window line without a flag"; pass=$((pass+1));; esac
# --since DATE form: 2026-06-15 keeps the 06-15 and 06-16 rows.
EC=0
out=$(bash "$SCRIPT" --file "$windowfix" --since 2026-06-15 2>&1) || EC=$?
assert_eq 0 "$EC" "window: --since exits 0"
assert_contains "Window:              since 2026-06-15T00:00:00Z  (2 of 3 rows)" "$out" "window: --since header shows cutoff and counts"
assert_contains "Total invocations:   2" "$out" "window: --since drops the pre-cutoff row"
assert_contains "Tokens avoided (≈):  500" "$out" "window: --since tokens summed over window only"
assert_contains "Time range:          2026-06-15T08:00:00Z" "$out" "window: --since first ts is in-window"
# --since full ISO timestamp form: keeps only the 06-16 row.
out=$(bash "$SCRIPT" --file "$windowfix" --since 2026-06-16T00:00:00Z 2>&1)
assert_contains "Total invocations:   1" "$out" "window: --since ISO timestamp keeps one row"
assert_contains "Tokens avoided (≈):  300" "$out" "window: --since ISO tokens over one row"
# Window that matches nothing -> exit 0 with an explicit note (not the empty-file note).
EC=0
out=$(bash "$SCRIPT" --file "$windowfix" --since 2030-01-01 2>&1) || EC=$?
assert_eq 0 "$EC" "window: empty window exits 0"
assert_contains "no rows in window" "$out" "window: empty window gives a windowed note, not 'empty file'"
rm -f "$windowfix"

# 18. --days window: relative to now. Build one row ~now and one ~100 days old;
# --days 30 keeps only the recent one.
now_s=$(date -u +%s)
recent_ts=$(jq -rn --argjson n "$now_s" '$n | todateiso8601')
old_ts=$(jq -rn --argjson n "$now_s" '($n - 100 * 86400) | todateiso8601')
daysfix=$(mktemp)
jq -nc --arg t "$recent_ts" '{ts:$t, source:"delegate", tier:"prose", model:"q", duration_ms:4000, exit_status:0, estimated_tokens_avoided:100}' >> "$daysfix"
jq -nc --arg t "$old_ts" '{ts:$t, source:"delegate", tier:"prose", model:"q", duration_ms:4000, exit_status:0, estimated_tokens_avoided:999}' >> "$daysfix"
EC=0
out=$(bash "$SCRIPT" --file "$daysfix" --days 30 2>&1) || EC=$?
assert_eq 0 "$EC" "window: --days exits 0"
assert_contains "Window:" "$out" "window: --days prints a Window line"
assert_contains "Total invocations:   1" "$out" "window: --days 30 keeps the recent row only"
assert_contains "Tokens avoided (≈):  100" "$out" "window: --days 30 excludes the 100-day-old row"
rm -f "$daysfix"

# 19. Window arg validation: mutually exclusive flags and malformed values exit 2.
vfix=$(mktemp)
echo '{"ts":"2026-06-16T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":1,"exit_status":0,"estimated_tokens_avoided":1}' > "$vfix"
EC=0; out=$(bash "$SCRIPT" --file "$vfix" --since 2026-06-15 --days 5 2>&1) || EC=$?
assert_eq 2 "$EC" "window: --since + --days together -> exit 2"
assert_contains "either --since or --days" "$out" "window: mutual-exclusion message"
EC=0; out=$(bash "$SCRIPT" --file "$vfix" --since not-a-date 2>&1) || EC=$?
assert_eq 2 "$EC" "window: invalid --since -> exit 2"
assert_contains "invalid --since" "$out" "window: invalid --since message"
EC=0; out=$(bash "$SCRIPT" --file "$vfix" --days abc 2>&1) || EC=$?
assert_eq 2 "$EC" "window: non-integer --days -> exit 2"
assert_contains "positive integer" "$out" "window: --days integer message"
EC=0; out=$(bash "$SCRIPT" --file "$vfix" --days 0 2>&1) || EC=$?
assert_eq 2 "$EC" "window: --days 0 -> exit 2"
# Value-taking flags with no following value exit 2 cleanly — under set -u this
# would otherwise crash with 'unbound variable' (gemini/Copilot HIGH on PR #312).
for flag in --file --since --days; do
  EC=0; out=$(bash "$SCRIPT" "$flag" 2>&1) || EC=$?
  assert_eq 2 "$EC" "window: $flag with no value -> exit 2 (not unbound-var crash)"
  assert_contains "requires" "$out" "window: $flag missing-value message"
done
rm -f "$vfix"

# 20. Scaffold verdict (supervised-draft-delegation G1). A third outcome
# distinct from hit and miss: a discarded-but-useful draft. It must report as
# its own count in the calibration sections, must NOT be folded into hits or
# misses, and a scaffold-covered delegation counts toward coverage. Fixture:
# 4 code-draft recipe delegations — D1 human HIT, D2 human MISS, D3 human
# SCAFFOLD, D4 untracked. Expected: hits=1 misses=1 scaffold=1 untracked=1,
# coverage=75% (3 of 4 covered).
scaf=$(mktemp)
cat > "$scaf" <<'EOF'
{"ts":"2026-06-22T10:00:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-22T10:05:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4100,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-06-22T10:10:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":120}
{"ts":"2026-06-22T10:15:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4300,"exit_status":0,"estimated_tokens_avoided":130}
{"ts":"2026-06-22T20:00:00Z","source":"feedback","ref_ts":"2026-06-22T10:00:00Z","kept":true}
{"ts":"2026-06-22T20:01:00Z","source":"feedback","ref_ts":"2026-06-22T10:05:00Z","kept":false,"reason":"rewrote entirely"}
{"ts":"2026-06-22T20:02:00Z","source":"feedback","ref_ts":"2026-06-22T10:10:00Z","kept":false,"scaffold":true,"reason":"approach was right, code discarded"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$scaf" 2>&1) || EC=$?
assert_eq 0 "$EC" "scaffold: exits 0"
assert_contains "Delegation feedback (hit/miss/scaffold):" "$out" "scaffold: section header is self-describing when scaffold rows present"
assert_contains "Recipe delegations (calibration signal): n=4  hits=1  misses=1  scaffold=1  untracked=1  coverage=75%" "$out" "scaffold: headline reports scaffold as its own count, not folded into hits/misses"
# Per-tier row carries the scaffold column.
code_tier_line=$(printf '%s\n' "$out" | grep -E "^    code" | tail -1)
assert_contains "scaffold=1" "$code_tier_line" "scaffold: per-tier row carries scaffold column"
assert_contains "hits=1" "$code_tier_line" "scaffold: per-tier hits unchanged by scaffold"
assert_contains "misses=1" "$code_tier_line" "scaffold: per-tier misses excludes the scaffold"
# Per-recipe row carries the scaffold column.
recipe_line=$(printf '%s\n' "$out" | grep -E "^  code-draft" | tail -1)
assert_contains "scaffold=1" "$recipe_line" "scaffold: per-recipe row carries scaffold column"
rm -f "$scaf"

# 20b. Negative gate: a fixture with hit/miss but NO scaffold row must NOT
# print any `scaffold=` column — legacy output stays byte-for-byte as before.
noscaf=$(mktemp)
cat > "$noscaf" <<'EOF'
{"ts":"2026-06-22T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-22T20:00:00Z","source":"feedback","ref_ts":"2026-06-22T10:00:00Z","kept":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$noscaf" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-scaffold: exits 0"
assert_contains "Delegation feedback (hit/miss):" "$out" "no-scaffold: section header stays the legacy 'hit/miss' form"
case "$out" in
  *"hit/miss/scaffold"*) echo "  FAIL  no-scaffold: header must not advertise scaffold without scaffold rows"; fail=$((fail+1));;
  *) echo "  PASS  no-scaffold: header omits scaffold without scaffold rows"; pass=$((pass+1));;
esac
case "$out" in
  *"scaffold="*) echo "  FAIL  no-scaffold: scaffold= column must be absent without scaffold rows"; fail=$((fail+1));;
  *) echo "  PASS  no-scaffold: scaffold= column absent without scaffold rows"; pass=$((pass+1));;
esac
assert_contains "Recipe delegations (calibration signal): n=1  hits=1  misses=0  untracked=0  coverage=100%" "$out" "no-scaffold: legacy line shape unchanged"
rm -f "$noscaf"

# 20c. Agent-tier scaffold coexists with human verdicts. Fixture: D1 human HIT,
# D2 agent SCAFFOLD. The agent column counts the agent verdict (coverage), the
# Agent-observed line reports a scaffold count alongside used/rewrote, and the
# human hit-rate is unaffected by the agent scaffold.
agentscaf=$(mktemp)
cat > "$agentscaf" <<'EOF'
{"ts":"2026-06-22T11:00:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-22T11:05:00Z","source":"delegate","recipe":"code-draft","tier":"code","model":"q","duration_ms":4100,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-06-22T21:00:00Z","source":"feedback","ref_ts":"2026-06-22T11:00:00Z","kept":true}
{"ts":"2026-06-22T21:01:00Z","source":"feedback","ref_ts":"2026-06-22T11:05:00Z","kept":false,"scaffold":true,"verdict_source":"agent","reason":"divergent draft, kept the idea"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$agentscaf" 2>&1) || EC=$?
assert_eq 0 "$EC" "agent-scaffold: exits 0"
assert_contains "Recipe delegations (calibration signal): n=2  hits=1  misses=0  scaffold=0  agent=1  untracked=0  coverage=100%" "$out" "agent-scaffold: human hits unaffected; agent scaffold counts in agent+coverage, not human scaffold"
assert_contains "Agent-observed (usage, not quality): n=1  used=0  rewrote=0  scaffold=1  usage_rate=0%" "$out" "agent-scaffold: Agent-observed line reports scaffold count"
rm -f "$agentscaf"

# Tokens-avoided decomposition (#412). estimated_tokens_avoided is written on
# every row including failures and rewritten drafts, so the bare headline reads
# as a saving when much of it is not. The headline itself is deliberately
# unchanged (the cross-source assertion above pins that); the qualification is
# printed beneath it.
decomp=$(mktemp)
cat > "$decomp" <<'EOF'
{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":1000}
{"ts":"2026-04-29T08:01:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":200}
{"ts":"2026-04-29T08:02:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":300}
{"ts":"2026-04-29T08:03:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":400}
{"ts":"2026-04-29T08:04:00Z","source":"delegate","tier":"prose","exit_status":3,"estimated_tokens_avoided":77}
{"ts":"2026-04-29T08:05:00Z","source":"experiment","session":"s1","estimated_tokens_avoided":55}
{"ts":"2026-04-29T09:00:00Z","source":"feedback","ref_ts":"2026-04-29T08:00:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-04-29T09:01:00Z","source":"feedback","ref_ts":"2026-04-29T08:01:00Z","kept":false,"verdict_source":"agent"}
{"ts":"2026-04-29T09:02:00Z","source":"feedback","ref_ts":"2026-04-29T08:02:00Z","kept":false,"scaffold":true,"verdict_source":"agent"}
{"ts":"2026-04-29T09:03:00Z","source":"feedback","ref_ts":"2026-04-29T08:03:00Z","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$decomp" 2>&1)
# 1000+200+300+400+77+55 = 2032, unchanged and still cross-source.
assert_contains "Tokens avoided (≈):  2032" "$out" "decomposition: headline is unchanged and still cross-source"
assert_contains "excluded: experiment rows       tokens≈55  n=1" "$out" "decomposition: experiment rows excluded"
assert_contains "excluded: failed delegations    tokens≈77  n=1" "$out" "decomposition: failed calls excluded"
assert_contains "successful delegations          tokens≈1900  n=4" "$out" "decomposition: successful subtotal"
# 55 + 77 + 1900 = 2032: the sub-lines reconcile to the headline exactly.
# 1000 (agent hit) + 400 (human hit, no agent verdict) — verdicts pool
# agent-first then human, so a human-only verdict lands in a real bucket.
assert_contains "shipped as-is     tokens≈1400  73.7%  n=2" "$out" "decomposition: agent and human hits both count as shipped"
assert_contains "rewritten         tokens≈200  10.5%  n=1" "$out" "decomposition: agent miss is rewritten"
assert_contains "used as scaffold  tokens≈300  15.8%  n=1" "$out" "decomposition: scaffold is its own bucket"
# The 400-token row carries a HUMAN verdict and no agent one. Filing it under
# "no verdict" would be the exact mislabel this section exists to remove.
assert_contains "no verdict        tokens≈0  0.0%  n=0" "$out" "decomposition: a human-only verdict is not 'no verdict'"
rm -f "$decomp"

# A delegation carrying several verdicts is counted once, under its LAST.
# Iterating feedback rows instead would add the parent's tokens per verdict.
multi=$(mktemp)
cat > "$multi" <<'EOF'
{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":500}
{"ts":"2026-04-29T09:00:00Z","source":"feedback","ref_ts":"2026-04-29T08:00:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-04-29T09:01:00Z","source":"feedback","ref_ts":"2026-04-29T08:00:00Z","kept":false,"verdict_source":"agent"}
EOF
out=$(bash "$SCRIPT" --file "$multi" 2>&1)
assert_contains "successful delegations          tokens≈500  n=1" "$out" "multi-verdict: delegation counted once"
assert_contains "rewritten         tokens≈500  100.0%  n=1" "$out" "multi-verdict: last verdict wins"
assert_contains "shipped as-is     tokens≈0  0.0%  n=0" "$out" "multi-verdict: superseded verdict does not double-count"
rm -f "$multi"

# A row with no `source` field is a delegation (metrics-summary treats a missing
# source as delegate); filtering on .source=="delegate" would drop it and the
# buckets would stop reconciling with the headline.
nosrc=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","tier":"prose","exit_status":0,"estimated_tokens_avoided":640}' > "$nosrc"
out=$(bash "$SCRIPT" --file "$nosrc" 2>&1)
assert_contains "successful delegations          tokens≈640  n=1" "$out" "sourceless row counts as a delegation"
rm -f "$nosrc"

# No feedback at all: the whole successful total is unverdicted rather than the
# section vanishing. The existing feedback rollup sits inside `if n_feedback > 0`,
# which is why this block needs its own pass.
nofb=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":800}' > "$nofb"
out=$(bash "$SCRIPT" --file "$nofb" 2>&1)
assert_contains "no verdict        tokens≈800  100.0%  n=1" "$out" "no feedback: all tokens report as unverdicted"
rm -f "$nofb"

# Every delegation failed: jq's `[] | add` is null and `n / 0` aborts the whole
# program with exit 5, so both are guarded.
allfail=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":3,"estimated_tokens_avoided":90}' > "$allfail"
EC=0
out=$(bash "$SCRIPT" --file "$allfail" 2>&1) || EC=$?
assert_eq 0 "$EC" "all-failed file: exits 0"
assert_contains "successful delegations          tokens≈0  n=0" "$out" "all-failed file: reports 0, not null"
# Scoped to this block's own lines: `p50=nullms` in Per-source is a pre-existing
# null of the same class in a different section, out of scope here.
decomp_lines=$(printf '%s\n' "$out" | grep -E '^  (excluded|successful)|^    ' || true)
case "$decomp_lines" in
  *null*) assert_eq "no null" "null printed" "all-failed file: no null in the decomposition" ;;
  *)      assert_eq "no null" "no null" "all-failed file: no null in the decomposition" ;;
esac
rm -f "$allfail"

# Agent self-flattery: of the output the agent chose to ship, how much did a
# person judge not good. Directional on purpose — a symmetric agreement rate
# between the two tiers measures nothing, because they answer different
# questions and a human MISS beside an agent HIT is two compatible facts.
# A file whose delegate rows carry no estimated_tokens_avoided made `add`
# return null, which @tsv renders as an empty field — and because tab is IFS
# whitespace, bash read collapsed the double-tab and shifted every later column
# left, so errors/delegate/experiment were all wrong at once with no error.
shift_fx=$(mktemp)
cat > "$shift_fx" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
EOF
out=$(bash "$SCRIPT" --file "$shift_fx" 2>&1)
assert_contains "Total invocations:   2  (delegate=2, experiment=0)" "$out" "null tokens: source counts do not shift"
assert_contains "Errors (non-zero):   0" "$out" "null tokens: error count does not shift"
assert_contains "Tokens avoided (≈):  0" "$out" "null tokens: prints 0, not empty"
rm -f "$shift_fx"

sf=$(mktemp)
cat > "$sf" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:02:00Z","source":"delegate","recipe":"pr-description","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:03:00Z","source":"delegate","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","ref_ts":"2026-06-01T09:01:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","ref_ts":"2026-06-01T09:01:00Z","kept":true}
{"ts":"2026-06-01T10:04:00Z","source":"feedback","ref_ts":"2026-06-01T09:02:00Z","kept":false,"verdict_source":"agent"}
{"ts":"2026-06-01T10:05:00Z","source":"feedback","ref_ts":"2026-06-01T09:02:00Z","kept":false}
{"ts":"2026-06-01T10:06:00Z","source":"feedback","ref_ts":"2026-06-01T09:03:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-01T10:07:00Z","source":"feedback","ref_ts":"2026-06-01T09:03:00Z","kept":false}
EOF
out=$(bash "$SCRIPT" --file "$sf" 2>&1)
# Two recipe rows carry agent=hit AND a human verdict: 09:00 (human miss) and
# 09:01 (human hit). 09:02 is agent=miss so it is not a shipped output. 09:03
# has no recipe, so it lives in the Raw block and is out of this scope.
assert_contains "Agent self-flattery (human verdict on agent-shipped output): n=2  human-miss=1  rate=50%" "$out" \
  "self-flattery: conditional on agent-shipped, scoped to recipe delegations"
rm -f "$sf"

# It is a conditional, not an agreement rate: an agent MISS beside a human MISS
# is not counted, because the agent did not ship that output.
sf2=$(mktemp)
cat > "$sf2" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false,"verdict_source":"agent"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false}
EOF
out=$(bash "$SCRIPT" --file "$sf2" 2>&1)
case "$out" in
  *"self-flattery"*) assert_eq "absent" "present" "self-flattery: an agent MISS pair is not counted" ;;
  *)                 assert_eq "absent" "absent"  "self-flattery: an agent MISS pair is not counted" ;;
esac
rm -f "$sf2"

# Silent when no pair exists, so single-tier files print exactly as before.
sf3=$(mktemp)
cat > "$sf3" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true,"verdict_source":"agent"}
EOF
out=$(bash "$SCRIPT" --file "$sf3" 2>&1)
case "$out" in
  *"self-flattery"*) assert_eq "absent" "present" "self-flattery: silent with no human verdict to pair" ;;
  *)                 assert_eq "absent" "absent"  "self-flattery: silent with no human verdict to pair" ;;
esac
rm -f "$sf3"

# Captured-pair coverage (#461 follow-up). The two ways a rejection acquires its
# shipped half are not interchangeable — `--final` needs the caller to remember,
# the boundary hook infers it from a credited post — so the line splits them.
# `inferred=0` is the whole reason it exists: the hook capture shipped in #457
# and did not fire once for eleven days, and the field simply being absent from
# every row was indistinguishable from having no reply traffic at all.
cp=$(mktemp)
cat > "$cp" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:02:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:03:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false,"scaffold":true,"final_file":"a.final.txt","final_source":"posted"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:01:00Z","kept":false,"final_file":"b.final.txt"}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","ref_ts":"2026-06-01T09:02:00Z","kept":false}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","ref_ts":"2026-06-01T09:03:00Z","kept":true,"final_file":"d.final.txt"}
EOF
out=$(bash "$SCRIPT" --file "$cp" 2>&1)
assert_contains "Captured pairs (rejections with the shipped text stored): n=2/3  inferred=1  by-hand=1" "$out" \
  "captured pairs: inferred and hand-supplied are counted apart, and a kept row is not a rejection"
rm -f "$cp"

# The absent case is the one that mattered: every final hand-supplied reads as
# inferred=0, which is a claim about the hook rather than a missing field.
cp2=$(mktemp)
cat > "$cp2" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false,"final_file":"b.final.txt"}
EOF
out=$(bash "$SCRIPT" --file "$cp2" 2>&1)
assert_contains "n=1/1  inferred=0  by-hand=1" "$out" \
  "captured pairs: a corpus with no hook capture reports inferred=0"
rm -f "$cp2"

# Silent with nothing to report, so a file of clean hits prints as before.
cp3=$(mktemp)
cat > "$cp3" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$cp3" 2>&1)
case "$out" in
  *"Captured pairs"*) assert_eq "absent" "present" "captured pairs: silent when nothing was rejected" ;;
  *)                  assert_eq "absent" "absent"  "captured pairs: silent when nothing was rejected" ;;
esac
rm -f "$cp3"

# The --since / --days window reaches this line like every other section.
cp4=$(mktemp)
cat > "$cp4" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false,"final_file":"old.final.txt"}
{"ts":"2026-07-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-07-01T10:00:00Z","source":"feedback","ref_ts":"2026-07-01T09:00:00Z","kept":false,"final_file":"new.final.txt","final_source":"posted"}
EOF
out=$(bash "$SCRIPT" --file "$cp4" --since 2026-06-15 2>&1)
assert_contains "n=1/1  inferred=1  by-hand=0" "$out" \
  "captured pairs: --since windows the line with the rest of the report"
rm -f "$cp4"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
