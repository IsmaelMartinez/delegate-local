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
rm -f "$fixture"

# 4. Mixed-source fixture (#552): feedback and opportunity rows are not calls,
# so they stay out of "Total invocations" and "Top models", and a session id
# on a delegate row is not an experiment (no script writes one any more).
mixed=$(mktemp)
cat > "$mixed" <<'EOF'
{"ts":"2026-05-04T08:00:00Z","source":"delegate","tier":"prose","model":"qwen3.6:35b-a3b","session":"s-1","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-04T08:05:00Z","tier":"prose","model":"qwen3.6:35b-a3b","session":"s-1","duration_ms":4300,"exit_status":0,"estimated_tokens_avoided":140}
{"ts":"2026-05-04T09:00:00Z","source":"feedback","ref_ts":"2026-05-04T08:00:00Z","kept":true,"session":"s-1"}
{"ts":"2026-05-04T09:01:00Z","source":"opportunity","boundary":"git-commit","delegated":true,"session":"s-1"}
{"ts":"2026-05-04T09:02:00Z","source":"opportunity","boundary":"git-commit","delegated":false,"session":"s-1"}
{"ts":"2026-05-04T09:03:00Z","source":"opportunity","boundary":"git-commit","delegated":false,"session":"s-1"}
EOF

EC=0
out=$(bash "$SCRIPT" --file "$mixed" 2>&1) || EC=$?
assert_eq 0 "$EC" "mixed: exits 0"
assert_contains "Total invocations:   2  (not counted: feedback=1, opportunity=3)" "$out" "mixed: only call rows are invocations"
assert_contains "Tokens avoided (≈):  240" "$out" "mixed: tokens avoided sums call rows"
assert_contains "Per-source:" "$out" "mixed: per-source header present"
assert_contains "Per-tier (delegate):" "$out" "mixed: per-tier header present for delegate rows"
top=$(printf '%s\n' "$out" | sed -n '/^Top models:/,$p')
assert_eq "Top models:
  2  qwen3.6:35b-a3b" "$top" "mixed: Top models lists call rows only, no null from opportunity rows"
case "$out" in
  *"Per-session"*|*"experiment="*) assert_eq "absent" "present" "mixed: no experiment or per-session section" ;;
  *)                               assert_eq "absent" "absent"  "mixed: no experiment or per-session section" ;;
esac
rm -f "$mixed"

# 4b. Percentiles (#552): index floor(n*p/100) clamped to n-1. The old clamp
# compared the index with `length` of a NUMBER (its absolute value), so it
# always fired and p95 came back one element low.
p95fx=$(mktemp)
for ms in 100 200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500 1600 1700 1800 1900 99999; do
  printf '{"ts":"2026-05-04T08:00:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"m","duration_ms":%s,"exit_status":0,"estimated_tokens_avoided":1}\n' "$ms"
done > "$p95fx"
printf '%s\n' '{"ts":"2026-05-04T08:00:00Z","source":"delegate","backend":"ollama","tier":"code","model":"m","duration_ms":200,"exit_status":0,"estimated_tokens_avoided":1}' \
  '{"ts":"2026-05-04T08:00:00Z","source":"delegate","backend":"ollama","tier":"code","model":"m","duration_ms":100,"exit_status":0,"estimated_tokens_avoided":1}' >> "$p95fx"
out=$(bash "$SCRIPT" --file "$p95fx" 2>&1)
assert_contains "prose           n=20  p50=1100ms  p95=99999ms" "$out" "percentile: per-tier p95 reaches the top element at n=20"
assert_contains "code            n=2  p50=200ms  p95=200ms" "$out" "percentile: per-tier p95 at n=2 is the larger element"
assert_contains "mlx         n=20  tokens≈20  p50=1100ms  p95=99999ms" "$out" "percentile: per-backend p95 uses the same definition"
assert_contains "delegate      n=22  tokens≈22  p50=1000ms  p95=1900ms" "$out" "percentile: per-source p95 at n=22"
rm -f "$p95fx"

# 5. Feedback rollup: a miss (kept:false) is counted, not dropped by jq's
# `//` treating false as absent.
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
assert_contains "Total invocations:   4  (not counted: feedback=3, opportunity=0)" "$out" "feedback: 4 delegate invocations counted"
assert_contains "Delegation feedback (hit/miss):" "$out" "feedback: section header"
assert_contains "prose" "$out" "feedback: prose row appears"
assert_contains "reasoning" "$out" "feedback: reasoning row appears"
assert_contains "prose           n=2  hits=1  misses=1  untracked=0" "$out" "feedback: prose hit/miss exact counts"
assert_contains "reasoning       n=2  hits=0  misses=1  untracked=1" "$out" "feedback: reasoning miss not silently dropped"
assert_contains "coverage=75%" "$out" "feedback: recipe verdict coverage headline (recipe-scoped)"
# Feedback rows carry no token field and must not inflate the sum.
assert_contains "Tokens avoided (≈):  530" "$out" "feedback: tokens not inflated by feedback rows"
rm -f "$fb"

# 5b. Failed delegations (exit_status != 0) produced no output to judge, so
# they leave the coverage denominator: 100% (1/1), not 50% (1/2).
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

# 6. Latest feedback wins: a later miss overrides an earlier hit on the same row.
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

# 7. Per-backend section is hidden with a single backend.
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

# 8. Two backends: the Per-backend section appears.
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

# 9. Rows with no backend field are bucketed as 'ollama'.
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
assert_contains "ollama" "$out" "back-compat: pre-2026-05 rows bucketed under ollama"
assert_contains "n=2" "$out" "back-compat: ollama bucket gets the 2 unset-backend rows"
assert_contains "n=1" "$out" "back-compat: mlx bucket gets its single row"
rm -f "$backcompat"

# 10. Missing estimated_tokens_avoided / duration_ms default to 0 in the
# Per-backend line rather than rendering "null".
sparse=$(mktemp)
cat > "$sparse" <<'EOF'
{"ts":"2026-05-12T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-05-12T10:05:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"m"}
{"ts":"2026-05-12T10:10:00Z","source":"delegate","backend":"mlx","tier":"prose","model":"m"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$sparse" 2>&1) || EC=$?
assert_eq 0 "$EC" "sparse: exits 0"
# Scoped to the Per-backend section only.
per_backend=$(echo "$out" | awk '/^Per-backend \(delegate\):/{flag=1; next} /^$/{flag=0} flag')
case "$per_backend" in
  *"null"*) echo "  FAIL  sparse: 'null' leaked into Per-backend output ($per_backend)"; fail=$((fail+1));;
  *) echo "  PASS  sparse: no 'null' in Per-backend output"; pass=$((pass+1));;
esac
assert_contains "tokens≈0" "$per_backend" "sparse: missing tokens default to 0 in Per-backend"
assert_contains "p50=0ms" "$per_backend" "sparse: missing duration_ms defaults to 0 in Per-backend p50"
rm -f "$sparse"

# 11. Per-project section with two projects: hit/miss/untracked and p50 per project.
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

# 12. A single project hides the section (projectless rows are their own
# bucket, see 12d).
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

# 13. Per-recipe section groups by recipe with hit/miss/untracked.
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

# 15. Verdict coverage is scoped to recipe delegations; raw calls are reported
# separately and do not inflate the recipe untracked count.
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

# 12. Trigger rate (#277): opportunity rows drive a per-project section and
# are not counted as invocations or errors (they carry no exit_status).
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
assert_contains "Total invocations:   1  (not counted: feedback=0, opportunity=3)" "$out" "trigger-rate: only the delegate row counts as an invocation"
assert_contains "Errors (non-zero):   0" "$out" "trigger-rate: opportunity rows not miscounted as errors"
assert_contains "Trigger rate (commit/PR/release/comment boundaries):" "$out" "trigger-rate: section header present"
assert_contains "alpha" "$out" "trigger-rate: alpha project listed"
assert_contains "beta" "$out" "trigger-rate: beta project listed"
assert_contains "opportunities=2  delegated=1  missed=1  rate=50%" "$out" "trigger-rate: alpha 50% (2 opps, 1 delegated)"
assert_contains "opportunities=1  delegated=0  missed=1  rate=0%" "$out" "trigger-rate: beta 0% (1 opp, missed)"
case "$out" in
  *"opportunity     n="*) echo "  FAIL  trigger-rate: opportunity must not appear as a Per-source call row"; fail=$((fail+1));;
  *) echo "  PASS  trigger-rate: opportunity excluded from Per-source rollup"; pass=$((pass+1));;
esac
rm -f "$opp"

# 12b. Legacy state:"pre-drafted" rows count as ordinary misses (#465).
predraft=$(mktemp)
cat > "$predraft" <<'EOF'
{"ts":"2026-06-08T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true}
{"ts":"2026-06-08T10:30:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false}
{"ts":"2026-06-08T10:40:00Z","source":"opportunity","project":"alpha","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":false,"state":"pre-drafted"}
{"ts":"2026-06-08T10:45:00Z","source":"opportunity","project":"alpha","boundary":"issue-create","suggested_recipe":"github-issue-body","delegated":false,"state":"pre-drafted"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$predraft" 2>&1) || EC=$?
assert_eq 0 "$EC" "legacy pre-drafted: exits 0"
assert_contains "opportunities=4  delegated=1  missed=3  rate=25%" "$out" \
  "legacy pre-drafted: counted in the ratio like every other boundary (#465)"
case "$out" in
  *"pre-drafted="*) assert_eq "absent" "present" "legacy pre-drafted: no separate trailing count" ;;
  *)                assert_eq "absent" "absent"  "legacy pre-drafted: no separate trailing count" ;;
esac
rm -f "$predraft"

# 12c. Projectless opportunity rows (#476) print as one `(no project)` line
# after the per-project rows, never as null and never count-ranked above
# them (the bucket has 3 rows to alpha's 1).
noproj=$(mktemp)
cat > "$noproj" <<'EOF'
{"ts":"2026-06-08T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true}
{"ts":"2026-06-08T10:30:00Z","source":"opportunity","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":false}
{"ts":"2026-06-08T10:31:00Z","source":"opportunity","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":false}
{"ts":"2026-06-08T10:32:00Z","source":"opportunity","boundary":"issue-create","suggested_recipe":"github-issue-body","delegated":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$noproj" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-project opportunities: exits 0"
trig=$(sed -n '/^Trigger rate/,/^$/p' <<<"$out")
assert_contains "opportunities=1  delegated=1  missed=0  rate=100%" "$trig" \
  "no-project opportunities: the per-project row is unaffected"
noproj_line=$(grep -F '(no project)' <<<"$trig")
assert_contains "opportunities=3  delegated=1  missed=2  rate=33%" "$noproj_line" \
  "no-project opportunities: one labelled (no project) line carries their counts"
case "$trig" in
  *null*) assert_eq "absent" "present" "no-project opportunities: never printed as null" ;;
  *)      assert_eq "absent" "absent"  "no-project opportunities: never printed as null" ;;
esac
# Among the project rows; the `excluded …` footer is not one.
assert_contains "(no project)" "$(grep -F 'opportunities=' <<<"$trig" | tail -1)" \
  "no-project opportunities: listed after the per-project rows, not ranked by count"
rm -f "$noproj"

# 12e. The rate is about real drafting (#483): a `below_floor:true` row
# leaves the ratio; a `denied:true` row retried by the same session within
# the window leaves it (the retry counts instead) while an unretried denial
# stays a miss; an `enforce_skipped` row is a real miss.
floor=$(mktemp)
cat > "$floor" <<'EOF'
{"ts":"2026-09-13T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s1"}
{"ts":"2026-09-13T10:02:00Z","source":"opportunity","project":"alpha","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":false,"body_chars":280,"session":"s1"}
{"ts":"2026-09-13T10:03:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":200,"enforce_skipped":"no-provider","session":"s1"}
{"ts":"2026-09-13T10:04:00Z","source":"opportunity","project":"alpha","boundary":"pr-review-comment","suggested_recipe":"pr-review-reply","delegated":false,"body_chars":23,"below_floor":true,"session":"s1"}
{"ts":"2026-09-13T10:05:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s1"}
{"ts":"2026-09-13T10:07:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s1"}
{"ts":"2026-09-13T11:00:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s2"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$floor" 2>&1) || EC=$?
assert_eq 0 "$EC" "body floor: exits 0"
trig=$(sed -n '/^Trigger rate/,/^$/p' <<<"$out")
assert_contains "opportunities=5  delegated=2  missed=3  rate=40%" "$trig" \
  "body floor: below-floor and retried-denied rows leave the ratio; the no-provider miss and the unretried denial stay"
assert_contains "excluded 1 boundaries under the floor (20 chars for git-commit, 120 for the rest)" "$trig" \
  "body floor: one line under the table names the excluded count and the per-boundary floors"
assert_contains "excluded 1 denied attempts retried within 480m" "$trig" \
  "body floor: retried denials are reported on their own, not as misses"
# The floor named is the one in force, read with the hook's own guard.
out=$(DELEGATE_BOUNDARY_MIN_CHARS=80 bash "$SCRIPT" --file "$floor" 2>&1)
assert_contains "under 80 chars" "$out" "body floor: the line reads a numeric DELEGATE_BOUNDARY_MIN_CHARS"
out=$(DELEGATE_BOUNDARY_MIN_CHARS=lots bash "$SCRIPT" --file "$floor" 2>&1)
assert_contains "under the floor (20 chars for git-commit, 120 for the rest)" "$out" \
  "body floor: a non-numeric override falls back to the defaults, as the hook does"
# The retry window is the hook's, so a denial retried outside it is a miss.
out=$(DELEGATE_BOUNDARY_WINDOW_MIN=1 bash "$SCRIPT" --file "$floor" 2>&1)
assert_contains "opportunities=6  delegated=2  missed=4  rate=33%" "$out" \
  "body floor: a denial retried outside DELEGATE_BOUNDARY_WINDOW_MIN counts as a miss"
rm -f "$floor"
# 12e-ii. A retry is a later row that is itself a counted post: a denial
# followed by a below-floor or retry-cap row stays a miss.
notretry=$(mktemp)
cat > "$notretry" <<'EOF'
{"ts":"2026-09-13T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s1"}
{"ts":"2026-09-13T10:02:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":3,"below_floor":true,"session":"s1"}
{"ts":"2026-09-13T10:03:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s2"}
{"ts":"2026-09-13T10:04:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"enforce_skipped":"retry-cap","session":"s2"}
{"ts":"2026-09-13T10:05:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s3"}
{"ts":"2026-09-13T10:06:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s3"}
EOF
out=$(bash "$SCRIPT" --file "$notretry" 2>&1)
trig=$(sed -n '/^Trigger rate/,/^$/p' <<<"$out")
assert_contains "opportunities=4  delegated=1  missed=3  rate=25%" "$trig" \
  "retry: a below-floor or retry-cap row after a denial is not a retry; those denials stay misses"
assert_contains "excluded 1 denied attempts retried" "$trig" \
  "retry: only the denial followed by a real post is excluded"
rm -f "$notretry"
# 12e-iii. The retry must be the same repo's boundary, and "later" is append
# order, not a strictly greater second.
xrepo=$(mktemp)
cat > "$xrepo" <<'EOF'
{"ts":"2026-09-13T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s1"}
{"ts":"2026-09-13T10:02:00Z","source":"opportunity","project":"beta","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s1"}
{"ts":"2026-09-13T10:03:00Z","source":"opportunity","project":"gamma","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s2"}
{"ts":"2026-09-13T10:03:00Z","source":"opportunity","project":"gamma","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s2"}
{"ts":"2026-09-13T10:10:00Z","source":"opportunity","project":"delta","boundary":"git-commit","suggested_recipe":"commit-message","delegated":false,"body_chars":312,"denied":true,"session":"s3"}
{"ts":"2026-09-13T09:00:00Z","source":"opportunity","project":"delta","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true,"body_chars":312,"session":"s3"}
EOF
out=$(bash "$SCRIPT" --file "$xrepo" 2>&1)
trig=$(sed -n '/^Trigger rate/,/^$/p' <<<"$out")
assert_contains "alpha                 opportunities=1  delegated=0  missed=1  rate=0%" "$trig" \
  "retry: a later commit in another repo does not erase this repo's denial"
assert_contains "gamma                 opportunities=1  delegated=1  missed=0  rate=100%" "$trig" \
  "retry: a denial and its redraft in the same second count once"
# A row appended later but stamped earlier is not a retry: the window has a
# lower bound of zero.
assert_contains "delta                 opportunities=2  delegated=1  missed=1  rate=50%" "$trig" \
  "retry: a later-appended row with an earlier timestamp does not satisfy the window"
assert_contains "excluded 1 denied attempts retried" "$trig" \
  "retry: exactly the same-second redraft is the excluded denial"
rm -f "$xrepo"
# With nothing excluded the line still prints, so the floor is never silent.
opp2=$(mktemp)
cat > "$opp2" <<'EOF'
{"ts":"2026-09-13T10:01:00Z","source":"opportunity","project":"alpha","boundary":"git-commit","suggested_recipe":"commit-message","delegated":true}
EOF
out=$(bash "$SCRIPT" --file "$opp2" 2>&1)
assert_contains "excluded 0 boundaries under the floor" "$out" "body floor: the excluded line prints even at zero"
case "$out" in
  *"denied attempts"*) assert_eq "absent" "present" "body floor: no denied line when nothing was denied" ;;
  *)                   assert_eq "absent" "absent"  "body floor: no denied line when nothing was denied" ;;
esac
rm -f "$opp2"

# 12d. The per-project delegate section lists projectless rows the same way
# (#476): `(no project)`, after the named projects, never count-ranked above one.
noprojdel=$(mktemp)
cat > "$noprojdel" <<'EOF'
{"ts":"2026-06-08T10:00:00Z","source":"delegate","project":"alpha","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-08T10:05:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4200,"exit_status":0,"estimated_tokens_avoided":110}
{"ts":"2026-06-08T10:10:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4400,"exit_status":0,"estimated_tokens_avoided":120}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$noprojdel" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-project delegations: exits 0"
perproj=$(sed -n '/^Per-project (delegate)/,/^$/p' <<<"$out")
assert_contains "(no project)" "$perproj" "no-project delegations: labelled (no project), not (none)"
case "$perproj" in
  *"(none)"*) assert_eq "absent" "present" "no-project delegations: the old (none) label is gone" ;;
  *)          assert_eq "absent" "absent"  "no-project delegations: the old (none) label is gone" ;;
esac
assert_contains "n=2" "$(grep -F '(no project)' <<<"$perproj")" "no-project delegations: the line carries their count"
assert_contains "(no project)" "$(grep -v '^$' <<<"$perproj" | tail -1)" \
  "no-project delegations: listed after the named projects, not ranked by count"
rm -f "$noprojdel"

# 16. One verdict tier (ADR 0030): every feedback row counts whether or not
# it carries verdict_source, and the ADR 0015 agent= column and
# "usage, not quality" line are gone.
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
assert_contains "Recipe delegations (calibration signal): n=4  hits=2  misses=1  untracked=1  coverage=75%" "$out" "one tier: every feedback row counts in hits/misses, whether or not it carries verdict_source"
case "$out" in
  *"agent="*) echo "  FAIL  one tier: the agent= column is gone"; fail=$((fail+1));;
  *) echo "  PASS  one tier: the agent= column is gone"; pass=$((pass+1));;
esac
case "$out" in
  *"usage, not quality"*|*"Agent-observed"*) echo "  FAIL  one tier: the usage-not-quality line is gone"; fail=$((fail+1));;
  *) echo "  PASS  one tier: the usage-not-quality line is gone"; pass=$((pass+1));;
esac
assert_contains "commit-message" "$out" "one tier: per-recipe lists commit-message"
recipe_line=$(printf '%s\n' "$out" | grep -E "^  commit-message" | tail -1)
assert_contains "n=4  hits=2  misses=1  untracked=1" "$recipe_line" "one tier: per-recipe row counts every verdict"
rm -f "$agenttier"

# 16b. Two verdicts on one delegation are a revision, not two tiers: the later
# one by ts wins, and the delegation is covered once (untracked=0).
bothtier=$(mktemp)
cat > "$bothtier" <<'EOF'
{"ts":"2026-06-14T11:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-14T21:00:00Z","source":"feedback","ref_ts":"2026-06-14T11:00:00Z","kept":true}
{"ts":"2026-06-14T21:01:00Z","source":"feedback","ref_ts":"2026-06-14T11:00:00Z","kept":false,"verdict_source":"agent"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$bothtier" 2>&1) || EC=$?
assert_eq 0 "$EC" "revision: exits 0"
assert_contains "Recipe delegations (calibration signal): n=1  hits=0  misses=1  untracked=0  coverage=100%" "$out" "revision: the later verdict wins regardless of which row carries verdict_source"
rm -f "$bothtier"

# 16c. A file of untagged legacy rows prints the same line shape.
noagent=$(mktemp)
cat > "$noagent" <<'EOF'
{"ts":"2026-06-14T12:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-14T22:00:00Z","source":"feedback","ref_ts":"2026-06-14T12:00:00Z","kept":true}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$noagent" 2>&1) || EC=$?
assert_eq 0 "$EC" "legacy rows: exits 0"
assert_contains "Recipe delegations (calibration signal): n=1  hits=1  misses=0  untracked=0  coverage=100%" "$out" "legacy rows: line shape unchanged"
rm -f "$noagent"

# 17. --since restricts every section to rows at or after the cutoff.
windowfix=$(mktemp)
cat > "$windowfix" <<'EOF'
{"ts":"2026-01-01T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-15T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":200}
{"ts":"2026-06-16T08:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":4000,"exit_status":0,"estimated_tokens_avoided":300}
EOF
out=$(bash "$SCRIPT" --file "$windowfix" 2>&1)
assert_contains "Total invocations:   3" "$out" "window: no flag -> all 3 rows"
case "$out" in *"Window:"*) echo "  FAIL  window: no Window line without a flag"; fail=$((fail+1));; *) echo "  PASS  window: no Window line without a flag"; pass=$((pass+1));; esac
EC=0
out=$(bash "$SCRIPT" --file "$windowfix" --since 2026-06-15 2>&1) || EC=$?
assert_eq 0 "$EC" "window: --since exits 0"
assert_contains "Window:              since 2026-06-15T00:00:00Z  (2 of 3 rows)" "$out" "window: --since header shows cutoff and counts"
assert_contains "Total invocations:   2" "$out" "window: --since drops the pre-cutoff row"
assert_contains "Tokens avoided (≈):  500" "$out" "window: --since tokens summed over window only"
assert_contains "Time range:          2026-06-15T08:00:00Z" "$out" "window: --since first ts is in-window"
out=$(bash "$SCRIPT" --file "$windowfix" --since 2026-06-16T00:00:00Z 2>&1)
assert_contains "Total invocations:   1" "$out" "window: --since ISO timestamp keeps one row"
assert_contains "Tokens avoided (≈):  300" "$out" "window: --since ISO tokens over one row"
# An empty window gets its own note, not the empty-file one.
EC=0
out=$(bash "$SCRIPT" --file "$windowfix" --since 2030-01-01 2>&1) || EC=$?
assert_eq 0 "$EC" "window: empty window exits 0"
assert_contains "no rows in window" "$out" "window: empty window gives a windowed note, not 'empty file'"
rm -f "$windowfix"

# 18. --days is relative to now.
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
# A value-taking flag with no value exits 2 rather than faulting under set -u.
for flag in --file --since --days; do
  EC=0; out=$(bash "$SCRIPT" "$flag" 2>&1) || EC=$?
  assert_eq 2 "$EC" "window: $flag with no value -> exit 2 (not unbound-var crash)"
  assert_contains "requires" "$out" "window: $flag missing-value message"
done
rm -f "$vfix"

# 20. A scaffold verdict is its own count, not folded into hits or misses,
# and counts toward coverage.
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
code_tier_line=$(printf '%s\n' "$out" | grep -E "^    code" | tail -1)
assert_contains "scaffold=1" "$code_tier_line" "scaffold: per-tier row carries scaffold column"
assert_contains "hits=1" "$code_tier_line" "scaffold: per-tier hits unchanged by scaffold"
assert_contains "misses=1" "$code_tier_line" "scaffold: per-tier misses excludes the scaffold"
recipe_line=$(printf '%s\n' "$out" | grep -E "^  code-draft" | tail -1)
assert_contains "scaffold=1" "$recipe_line" "scaffold: per-recipe row carries scaffold column"
rm -f "$scaf"

# 20b. Without a scaffold row no `scaffold=` column prints.
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

# 20c. A tagged scaffold beside an untagged hit: one tier, both count.
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
assert_contains "Recipe delegations (calibration signal): n=2  hits=1  misses=0  scaffold=1  untracked=0  coverage=100%" "$out" "agent-scaffold: a tagged scaffold counts in the headline scaffold column"
rm -f "$agentscaf"

# Tokens-avoided decomposition (#412): the headline is unchanged and the
# qualification prints beneath it.
decomp=$(mktemp)
cat > "$decomp" <<'EOF'
{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":1000}
{"ts":"2026-04-29T08:01:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":200}
{"ts":"2026-04-29T08:02:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":300}
{"ts":"2026-04-29T08:03:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":400}
{"ts":"2026-04-29T08:04:00Z","source":"delegate","tier":"prose","exit_status":3,"estimated_tokens_avoided":77}
{"ts":"2026-04-29T09:00:00Z","source":"feedback","ref_ts":"2026-04-29T08:00:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-04-29T09:01:00Z","source":"feedback","ref_ts":"2026-04-29T08:01:00Z","kept":false,"verdict_source":"agent"}
{"ts":"2026-04-29T09:02:00Z","source":"feedback","ref_ts":"2026-04-29T08:02:00Z","kept":false,"scaffold":true,"verdict_source":"agent"}
{"ts":"2026-04-29T09:03:00Z","source":"feedback","ref_ts":"2026-04-29T08:03:00Z","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$decomp" 2>&1)
# The sub-lines (77 + 1900) reconcile to the headline exactly.
assert_contains "Tokens avoided (≈):  1977" "$out" "decomposition: headline is unchanged and still cross-source"
assert_contains "excluded: failed delegations    tokens≈77  n=1" "$out" "decomposition: failed calls excluded"
assert_contains "successful delegations          tokens≈1900  n=4" "$out" "decomposition: successful subtotal"
# One tier: the tagged and the untagged hit land in the same bucket.
assert_contains "shipped as-is     tokens≈1400  73.7%  n=2" "$out" "decomposition: tagged and untagged hits both count as shipped"
assert_contains "rewritten         tokens≈200  10.5%  n=1" "$out" "decomposition: miss is rewritten"
assert_contains "used as scaffold  tokens≈300  15.8%  n=1" "$out" "decomposition: scaffold is its own bucket"
assert_contains "no verdict        tokens≈0  0.0%  n=0" "$out" "decomposition: an untagged verdict is not 'no verdict'"
rm -f "$decomp"

# A delegation with several verdicts is counted once, under its last.
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

# A row with no `source` field is a delegation, so the buckets still reconcile.
nosrc=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","tier":"prose","exit_status":0,"estimated_tokens_avoided":640}' > "$nosrc"
out=$(bash "$SCRIPT" --file "$nosrc" 2>&1)
assert_contains "successful delegations          tokens≈640  n=1" "$out" "sourceless row counts as a delegation"
rm -f "$nosrc"

# No feedback at all: the successful total is unverdicted, the section still prints.
nofb=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":0,"estimated_tokens_avoided":800}' > "$nofb"
out=$(bash "$SCRIPT" --file "$nofb" 2>&1)
assert_contains "no verdict        tokens≈800  100.0%  n=1" "$out" "no feedback: all tokens report as unverdicted"
rm -f "$nofb"

# Every delegation failed: jq's `[] | add` is null and `n / 0` aborts with exit 5.
allfail=$(mktemp)
printf '%s\n' '{"ts":"2026-04-29T08:00:00Z","source":"delegate","tier":"prose","exit_status":3,"estimated_tokens_avoided":90}' > "$allfail"
EC=0
out=$(bash "$SCRIPT" --file "$allfail" 2>&1) || EC=$?
assert_eq 0 "$EC" "all-failed file: exits 0"
assert_contains "successful delegations          tokens≈0  n=0" "$out" "all-failed file: reports 0, not null"
# Scoped to the decomposition lines; Per-source has its own null of the same class.
decomp_lines=$(printf '%s\n' "$out" | grep -E '^  (excluded|successful)|^    ' || true)
case "$decomp_lines" in
  *null*) assert_eq "no null" "null printed" "all-failed file: no null in the decomposition" ;;
  *)      assert_eq "no null" "no null" "all-failed file: no null in the decomposition" ;;
esac
rm -f "$allfail"

# Rows with no estimated_tokens_avoided: a null sum renders as an empty @tsv
# field, and bash read collapses the double tab and shifts the later columns.
shift_fx=$(mktemp)
cat > "$shift_fx" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
EOF
out=$(bash "$SCRIPT" --file "$shift_fx" 2>&1)
assert_contains "Total invocations:   2  (not counted: feedback=0, opportunity=0)" "$out" "null tokens: source counts do not shift"
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
# One tier: no ADR 0015 self-flattery line, the pairs are revisions and the
# later verdict wins; 09:03 has no recipe and lives in the Raw block.
case "$out" in
  *"self-flattery"*) assert_eq "absent" "present" "one tier: no self-flattery comparison line" ;;
  *)                 assert_eq "absent" "absent"  "one tier: no self-flattery comparison line" ;;
esac
assert_contains "Recipe delegations (calibration signal): n=3  hits=1  misses=2  untracked=0  coverage=100%" "$out" \
  "one tier: a tagged/untagged pair on one delegation resolves to the later verdict"
rm -f "$sf"

# A feedback row with no ref_ts and no ref_id joins nothing and must not
# abort the jq. Two projects so Per-project prints too.
nullref=$(mktemp)
cat > "$nullref" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"a","exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"b","exit_status":0,"estimated_tokens_avoided":100}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","kept":false,"reason":"orphan row with no ref","verdict_source":"agent"}
EOF
EC=0
out=$(bash "$SCRIPT" --file "$nullref" 2>&1) || EC=$?
assert_eq 0 "$EC" "null ref_ts: exits 0"
assert_contains "Recipe delegations (calibration signal): n=2  hits=1  misses=0  untracked=1  coverage=50%" "$out" "null ref_ts: the headline survives an unjoinable feedback row"
assert_contains "  a                     n=1  hits=1  misses=0  untracked=0" "$out" "null ref_ts: the per-project section survives"
assert_contains "  commit-message        n=2  hits=1  misses=0  untracked=1" "$out" "null ref_ts: the per-recipe section survives"
assert_contains "shipped as-is     tokens≈100  50.0%  n=1" "$out" "null ref_ts: the tokens decomposition survives"
case "$out" in
  *"Cannot use null"*|*"jq: error"*) assert_eq "no jq error" "jq error" "null ref_ts: no jq abort leaks to the output" ;;
  *) assert_eq "no jq error" "no jq error" "null ref_ts: no jq abort leaks to the output" ;;
esac
rm -f "$nullref"

# Join by ref_id first, ref_ts second (#481): a --id verdict lands on its own
# row only; a ref_ts-only row on a shared second reaches both siblings.
sib=$(mktemp)
cat > "$sib" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"p","exit_status":0,"estimated_tokens_avoided":100,"otel_span_id":"aaaa000000000001"}
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"p","exit_status":0,"estimated_tokens_avoided":300,"otel_span_id":"aaaa000000000002"}
{"ts":"2026-06-01T09:05:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"p","exit_status":0,"estimated_tokens_avoided":50,"otel_span_id":"aaaa000000000003"}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","ref_id":"aaaa000000000001","kept":true,"verdict_source":"agent"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:05:00Z","kept":false,"reason":"legacy row: ref_ts only","verdict_source":"agent"}
EOF
out=$(bash "$SCRIPT" --file "$sib" 2>&1)
assert_contains "Recipe delegations (calibration signal): n=3  hits=1  misses=1  untracked=1  coverage=66%" "$out" \
  "ref_id join: the --id verdict lands on its own row, the same-second sibling stays untracked, a ref_ts-only row still joins"
assert_contains "shipped as-is     tokens≈100  22.2%  n=1" "$out" "ref_id join: the decomposition credits only the verdicted sibling's tokens"
assert_contains "no verdict        tokens≈300  66.7%  n=1" "$out" "ref_id join: the sibling's tokens are unverdicted"
recipe_line=$(printf '%s\n' "$out" | grep -E "^  commit-message" | tail -1)
assert_contains "n=3  hits=1  misses=1  untracked=1" "$recipe_line" "ref_id join: the per-recipe row agrees"
rm -f "$sib"

sib2=$(mktemp)
cat > "$sib2" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"p","exit_status":0,"otel_span_id":"aaaa000000000001"}
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","project":"p","exit_status":0,"otel_span_id":"aaaa000000000002"}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$sib2" 2>&1)
assert_contains "Recipe delegations (calibration signal): n=2  hits=2  misses=0  untracked=0  coverage=100%" "$out" \
  "ref_id join: a legacy ref_ts-only verdict on a shared second still reaches both siblings"
rm -f "$sib2"

# Captured-pair coverage (#461) splits verdicts that adopted the hook's final
# (final_source:"posted") from ones whose caller passed --final.
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

# Every final hand-supplied reads as inferred=0: nothing was adopted.
cp2=$(mktemp)
cat > "$cp2" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":false,"final_file":"b.final.txt"}
EOF
out=$(bash "$SCRIPT" --file "$cp2" 2>&1)
assert_contains "n=1/1  inferred=0  by-hand=1" "$out" \
  "captured pairs: a corpus with no hook capture reports inferred=0"
rm -f "$cp2"

# inferred= counts adoption, not capture (#552): once callers pass --final the
# hook's <stem>.final.txt is never adopted, so inferred=0 while the hook still
# writes every credited post. hook-captured= reads the drafts dir beside the
# metrics file: a rejection counts when its draft's <stem>.final.txt exists and
# was not written by that verdict's own --final (final_file equal to the name
# and not "posted"; the hook never overwrites, a later --final gets .final.2).
hc=$(mktemp -d)
mkdir "$hc/drafts"
for s in sA sB sC sE; do printf 'shipped\n' > "$hc/drafts/$s.final.txt"; done
cat > "$hc/metrics.jsonl" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0,"otel_span_id":"a1","draft_file":"sA.draft.txt"}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0,"otel_span_id":"b1","draft_file":"sB.draft.txt"}
{"ts":"2026-06-01T09:02:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0,"otel_span_id":"c1","draft_file":"sC.draft.txt"}
{"ts":"2026-06-01T09:03:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0,"draft_file":"sD.draft.txt"}
{"ts":"2026-06-01T09:04:00Z","source":"delegate","recipe":"maintainer-reply","tier":"prose","exit_status":0,"otel_span_id":"e1","draft_file":"sE.draft.txt"}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","ref_id":"a1","kept":false,"final_file":"sA.final.2.txt"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:01:00Z","ref_id":"b1","kept":false,"final_file":"sB.final.txt","final_source":"posted"}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","ref_ts":"2026-06-01T09:02:00Z","ref_id":"c1","kept":false,"final_file":"sC.final.txt"}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","ref_ts":"2026-06-01T09:03:00Z","kept":false}
{"ts":"2026-06-01T10:04:00Z","source":"feedback","ref_ts":"2026-06-01T09:04:00Z","ref_id":"e1","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$hc/metrics.jsonl" 2>&1)
assert_contains "n=3/4  inferred=1  by-hand=2  hook-captured=2" "$out" \
  "captured pairs: hook-captured counts hook finals on disk, not the verdict's own --final or a kept row"
out=$(DELEGATE_METRICS_FILE="$hc/metrics.jsonl" bash "$SCRIPT" 2>&1)
assert_contains "hook-captured=2" "$out" "captured pairs: the drafts dir follows DELEGATE_METRICS_FILE"
rm -rf "$hc"

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
