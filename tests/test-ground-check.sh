#!/usr/bin/env bash
# Unit tests for scripts/ground-check.sh — offline, model-free. Builds a
# sandbox repo with the wrapper, the shared lib, and a MOCK delegate.sh whose
# canned verdicts (MOCK_VERDICTS) and exit code (MOCK_EXIT) the test controls,
# so the post-check (UNVERIFIED downgrade, UNPARSEABLE passthrough, clean field,
# exit-0-regardless, delegate-exit passthrough) is asserted without a model.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$REPO/scripts/ground-check.sh"
LIB="$REPO/experiments/lib/ground-substring.sh"

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
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpected '$needle' in:\n$haystack)"; fail=$((fail+1)); fi
}

# Sandbox: the wrapper computes repo_root from its own location, so place it +
# the shared lib + a mock delegate.sh under a temp repo layout.
make_sandbox() {
  local sb="$1"
  mkdir -p "$sb/scripts" "$sb/experiments/lib"
  cp "$WRAPPER" "$sb/scripts/ground-check.sh"; chmod +x "$sb/scripts/ground-check.sh"
  cp "$LIB" "$sb/experiments/lib/ground-substring.sh"
  cat > "$sb/scripts/delegate.sh" <<'EOF'
#!/usr/bin/env bash
# Mock delegate: consume the piped doc, emit the canned verdicts, exit as told.
cat >/dev/null
printf '%s\n' "$MOCK_VERDICTS"
exit "${MOCK_EXIT:-0}"
EOF
  chmod +x "$sb/scripts/delegate.sh"
}

EVID='The build adds a retry wrapper around the upload call and sets the timeout. It does not change the storage bucket.'
DOC=$(printf '%s\n\n=== CLAIMS ===\nC1: x\nC2: y\n' "$EVID")

run_wrapper() {  # $1=sandbox  (reads $DOC on stdin, MOCK_* from env)
  printf '%s' "$DOC" | bash "$1/scripts/ground-check.sh" 2>/dev/null
}

echo "=== ground-check.sh ==="

# 1. Fabricated quote is downgraded to UNVERIFIED; real quote stays SUPPORTED.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_EXIT=0
export MOCK_VERDICTS='C1: SUPPORTED — "adds a retry wrapper around the upload call"
C2: SUPPORTED — "this phrase is fabricated and absent"'
out=$(run_wrapper "$sb")
assert_contains 'C1: SUPPORTED — "adds a retry wrapper around the upload call"' "$out" "verified SUPPORTED kept"
assert_contains 'C2: UNVERIFIED — "this phrase is fabricated and absent"' "$out" "fabricated quote downgraded to UNVERIFIED"
assert_contains "clean=false" "$out" "downgrade → clean=false"
rm -rf "$sb"

# 2. A verified CONTRADICTED is kept and forces clean=false.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='C1: SUPPORTED — "adds a retry wrapper around the upload call"
C2: CONTRADICTED — "does not change the storage bucket"'
out=$(run_wrapper "$sb")
assert_contains 'C2: CONTRADICTED — "does not change the storage bucket"' "$out" "verified CONTRADICTED kept"
assert_contains "clean=false" "$out" "a CONTRADICTED present → clean=false"
rm -rf "$sb"

# 2b. Genuinely clean: only verified SUPPORTED.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='C1: SUPPORTED — "adds a retry wrapper around the upload call"'
out=$(run_wrapper "$sb")
assert_contains "clean=true" "$out" "all verified SUPPORTED → clean=true"
rm -rf "$sb"

# 3. Unparseable model line is emitted loudly, not dropped.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='Here is my analysis of the claims:
C1: SUPPORTED — "adds a retry wrapper around the upload call"'
out=$(run_wrapper "$sb")
assert_contains "UNPARSEABLE — Here is my analysis" "$out" "preamble line emitted as UNPARSEABLE"
assert_contains "clean=false" "$out" "unparseable → clean=false"
rm -rf "$sb"

# 3b. NOT-STATED is surfaced and forces clean=false.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='C1: NOT-STATED'
out=$(run_wrapper "$sb")
assert_contains "C1: NOT-STATED" "$out" "NOT-STATED surfaced"
assert_contains "clean=false" "$out" "NOT-STATED → clean=false"
rm -rf "$sb"

# 4. Summary line always present.
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='C1: NOT-STATED'
out=$(run_wrapper "$sb")
assert_contains "GROUND_CHECK_SUMMARY:" "$out" "summary line present"
rm -rf "$sb"

# 5. Exit 0 regardless of verdict mix (the advisory property).
sb=$(mktemp -d); make_sandbox "$sb"
export MOCK_VERDICTS='C1: UNVERIFIED — "x"
C2: NOT-STATED
C3: CONTRADICTED — "does not change the storage bucket"'
EC=0; printf '%s' "$DOC" | bash "$sb/scripts/ground-check.sh" >/dev/null 2>&1 || EC=$?
assert_eq "0" "$EC" "exit 0 regardless of verdict outcome"
rm -rf "$sb"

# 6. delegate.sh non-zero exit propagates unchanged (2/3/4).
for code in 2 3 4; do
  sb=$(mktemp -d); make_sandbox "$sb"
  export MOCK_EXIT="$code"
  export MOCK_VERDICTS='irrelevant'
  EC=0; printf '%s' "$DOC" | bash "$sb/scripts/ground-check.sh" >/dev/null 2>&1 || EC=$?
  assert_eq "$code" "$EC" "delegate exit $code propagates"
  rm -rf "$sb"
done
export MOCK_EXIT=0

# 7. --evidence-file / --claims-file mode.
sb=$(mktemp -d); make_sandbox "$sb"
ef="$sb/ev.txt"; cf="$sb/cl.txt"
printf '%s\n' "$EVID" > "$ef"
printf 'C1: x\n' > "$cf"
export MOCK_VERDICTS='C1: SUPPORTED — "adds a retry wrapper around the upload call"'
out=$(bash "$sb/scripts/ground-check.sh" --evidence-file "$ef" --claims-file "$cf" 2>/dev/null)
assert_contains "clean=true" "$out" "file-mode: verified SUPPORTED → clean=true"
rm -rf "$sb"

# 8. Unknown flag → exit 2.
EC=0; bash "$WRAPPER" --bogus </dev/null >/dev/null 2>&1 || EC=$?
assert_eq "2" "$EC" "unknown flag → exit 2"

unset MOCK_VERDICTS MOCK_EXIT
echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
