#!/usr/bin/env bash
# Unit tests for experiments/score-t3.sh.
# Builds synthetic raw output files and a minimal T3 fixture under a temp
# repo layout, then asserts the mechanical score behaves as documented.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t3.sh"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected '$expected', got '$actual')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in:\n$haystack)"; fail=$((fail+1)); fi
}

# Build a self-contained sandbox: a fake repo root with experiments/fixtures/
# and experiments/score-t3.sh. The script computes repo_root from its own
# location, so symlinking it into the sandbox makes it score against the
# sandbox fixture rather than the real one.
make_sandbox() {
  local sandbox="$1" snapshot="$2"
  mkdir -p "$sandbox/experiments/fixtures" "$sandbox/experiments/results/raw"
  cp "$SCRIPT" "$sandbox/experiments/score-t3.sh"
  chmod +x "$sandbox/experiments/score-t3.sh"
  cat > "$sandbox/experiments/fixtures/task-3-merge-patterns-${snapshot}.txt" <<'EOF'
abc1234 fix: align region card counts (#71)
def5678 simplify: phase 1 — drop one-off scripts (#66)
=== abc1234 fix: align region card counts (#71) ===
 src/pages/index.astro | 8 ++++----
=== def5678 simplify: phase 1 — drop one-off scripts (#66) ===
 docs/superpowers/plans/2026-04-28-simplify.md | 75 +++
 scripts/cross-copy-bios.ts                    | 123 ----
 scripts/enrich-candidates.ts                  | 88 ---
EOF
}

# Helper: build a raw output file containing one or more T3 reps.
# Args: <out_file> <body_for_rep_1> [<body_for_rep_2> ...]
build_raw() {
  local out="$1"; shift
  : > "$out"
  echo "MODEL: test-model" >> "$out"
  echo "DATE: 2026-05-01T00:00:00Z" >> "$out"
  echo "REPS: $#" >> "$out"
  echo "T3_SNAPSHOT: 2026-04-28" >> "$out"
  echo "" >> "$out"
  local rep=1
  for body in "$@"; do
    echo "===== T1-doc-drift rep $rep =====" >> "$out"
    echo "DURATION_SEC: 1" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    echo "(unrelated)" >> "$out"
    echo "" >> "$out"
    echo "===== T3-merge-patterns rep $rep =====" >> "$out"
    echo "DURATION_SEC: 5" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    printf '%s\n' "$body" >> "$out"
    echo "" >> "$out"
    rep=$((rep + 1))
  done
}

run_score() {
  local sandbox="$1" raw="$2"
  bash "$sandbox/experiments/score-t3.sh" "$raw" --t3-snapshot 2026-04-28 2>&1
}

echo "=== score-t3.sh ==="

# 1. NONE answer scores 1.0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw1.txt"
build_raw "$raw" "NONE"
out=$(run_score "$sandbox" "$raw")
assert_contains "T3_SUMMARY:" "$out" "NONE: produces summary line"
assert_contains "mean=1.0000" "$out" "NONE: mean is 1.0"
assert_contains "total_cited=1 total_claimed=1" "$out" "NONE: counted as 1/1"
rm -rf "$sandbox"

# 2. All claims supported (paths appear in fixture) → 1.0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw2.txt"
build_raw "$raw" "concern A | src/pages/index.astro
concern B | scripts/cross-copy-bios.ts"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=2 total_claimed=2" "$out" "all-supported: 2/2"
assert_contains "mean=1.0000" "$out" "all-supported: mean 1.0"
rm -rf "$sandbox"

# 3. Half supported → 0.5.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw3.txt"
build_raw "$raw" "real concern | src/pages/index.astro
fabricated | path/that/does/not/exist.ts"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=2" "$out" "half: 1/2"
assert_contains "mean=0.5000" "$out" "half: mean 0.5"
rm -rf "$sandbox"

# 4. No claims supported → 0.0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw4.txt"
build_raw "$raw" "fabricated A | nope/a.ts
fabricated B | nope/b.ts"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=0 total_claimed=2" "$out" "none-supported: 0/2"
assert_contains "mean=0.0000" "$out" "none-supported: mean 0.0"
rm -rf "$sandbox"

# 5. Empty body → 0.0 with claimed=0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw5.txt"
build_raw "$raw" ""
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=0 total_claimed=0" "$out" "empty: 0/0"
assert_contains "mean=0.0000" "$out" "empty: mean 0.0"
rm -rf "$sandbox"

# 6. Format-broken lines without `|` are excluded from denominator.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw6.txt"
build_raw "$raw" "Some preamble that should be ignored.
Here is my analysis:
real concern | src/pages/index.astro
Another paragraph without a pipe."
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=1" "$out" "format: only piped lines counted"
rm -rf "$sandbox"

# 7. Empty pattern (right side of |) is excluded.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw7.txt"
build_raw "$raw" "concern A | src/pages/index.astro
concern B | "
out=$(run_score "$sandbox" "$raw")
assert_contains "total_claimed=1" "$out" "empty pattern: not counted"
rm -rf "$sandbox"

# 8. Multiple reps: mean is computed across reps.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw8.txt"
build_raw "$raw" \
  "concern | src/pages/index.astro" \
  "concern | nope.ts"
out=$(run_score "$sandbox" "$raw")
assert_contains "reps=2" "$out" "two-reps: counted"
assert_contains "mean=0.5000" "$out" "two-reps: mean 0.5"
rm -rf "$sandbox"

# 9. Backticks/quotes around the pattern are stripped before lookup.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw9.txt"
build_raw "$raw" "concern | \`src/pages/index.astro\`"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=1" "$out" "backticks: stripped before lookup"
rm -rf "$sandbox"

# 10. Bad arg path -> usage error.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq "2" "$EC" "no-args: exit 2"
assert_contains "usage:" "$out" "no-args: usage on stderr"

# 11. Missing file -> usage error.
EC=0
out=$(bash "$SCRIPT" /nonexistent/path.txt 2>&1) || EC=$?
assert_eq "2" "$EC" "missing file: exit 2"

# 12. NONE with trailing punctuation (NONE.) still scores 1.0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw12.txt"
build_raw "$raw" "NONE."
out=$(run_score "$sandbox" "$raw")
assert_contains "mean=1.0000" "$out" "NONE with trailing dot still scores 1.0"
rm -rf "$sandbox"

# 13. Lowercase 'none' on its own line still scores 1.0.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw13.txt"
build_raw "$raw" "none"
out=$(run_score "$sandbox" "$raw")
assert_contains "mean=1.0000" "$out" "lowercase none scores 1.0"
rm -rf "$sandbox"

# 14a. Backtick span with trailing explanation: the span is extracted and
# matched against the fixture; explanatory text after the closing backtick
# does not break the match. Mirrors the MLX 2026-05-12 baseline pattern.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw14a.txt"
build_raw "$raw" "concern | \`src/pages/index.astro\` (grep for region card rendering)"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=1" "$out" "backtick span: extracted past trailing explanation"
rm -rf "$sandbox"

# 14b. Multiple backtick spans on one claim line — supported if ANY matches
# the fixture as a literal substring.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw14b.txt"
build_raw "$raw" "concern | first \`nope/missing.ts\`, fallback \`src/pages/index.astro\` for the real one"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=1" "$out" "backtick spans: any-of match"
rm -rf "$sandbox"

# 14c. Backtick span where every span is fabricated — claim is unsupported.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw14c.txt"
build_raw "$raw" "concern | \`nope/one.ts\` and also \`nope/two.ts\` neither exist"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=0 total_claimed=1" "$out" "backtick spans: all-fake -> unsupported"
rm -rf "$sandbox"

# 14d. Bare path with no backticks still falls through to the legacy
# substring path (the original behaviour is preserved for back-compat).
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw14d.txt"
build_raw "$raw" "concern | src/pages/index.astro"
out=$(run_score "$sandbox" "$raw")
assert_contains "total_cited=1 total_claimed=1" "$out" "bare path: back-compat substring match"
rm -rf "$sandbox"

# 15. 10+ reps: numeric iteration, rep-10 not sorted before rep-2.
# Build 10 reps where odd ones cite a real path and even ones cite a fake.
# Mean should be 5/10 = 0.5 regardless of glob ordering.
sandbox=$(mktemp -d); make_sandbox "$sandbox" 2026-04-28
raw="$sandbox/raw14.txt"
bodies=()
for i in 1 2 3 4 5 6 7 8 9 10; do
  if (( i % 2 == 1 )); then
    bodies+=("real | src/pages/index.astro")
  else
    bodies+=("fake | nope/${i}.ts")
  fi
done
build_raw "$raw" "${bodies[@]}"
out=$(run_score "$sandbox" "$raw")
assert_contains "reps=10" "$out" "10-reps: counted correctly"
assert_contains "mean=0.5000" "$out" "10-reps: numeric ordering gives correct mean"
rm -rf "$sandbox"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
