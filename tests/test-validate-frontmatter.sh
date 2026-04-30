#!/usr/bin/env bash
# Unit tests for scripts/validate-frontmatter.sh.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/validate-frontmatter.sh"
FIX="$REPO/tests/fixtures"

pass=0
fail=0

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/delegate-to-ollama"

assert_exit() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected $expected, got $actual)"; fail=$((fail+1)); fi
}

assert_stderr() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in stderr)"; fail=$((fail+1)); fi
}

# 1. Good frontmatter -> exit 0.
cp "$FIX/skill-good.md" "$WORKDIR/delegate-to-ollama/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-to-ollama/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "good frontmatter exits 0"

# 2. Missing frontmatter -> exit 1.
cp "$FIX/skill-no-frontmatter.md" "$WORKDIR/delegate-to-ollama/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-to-ollama/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "missing frontmatter exits 1"
assert_stderr "no frontmatter" "$out" "missing frontmatter: informative error"

# 3. Name mismatch -> exit 1.
cp "$FIX/skill-name-mismatch.md" "$WORKDIR/delegate-to-ollama/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-to-ollama/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "name mismatch exits 1"
assert_stderr "wrong-name" "$out" "name mismatch: prints offending name"

# 4. Bad name regex -> exit 1.
cp "$FIX/skill-bad-name.md" "$WORKDIR/delegate-to-ollama/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-to-ollama/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "bad name regex exits 1"
assert_stderr "regex" "$out" "bad name regex: error mentions regex"

# 5. Missing description -> exit 1.
cp "$FIX/skill-no-description.md" "$WORKDIR/delegate-to-ollama/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-to-ollama/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "missing description exits 1"
assert_stderr "description" "$out" "missing description: informative error"

# 6. Real SKILL.md must pass.
out=$(bash "$SCRIPT" "$REPO/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "real SKILL.md passes"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
