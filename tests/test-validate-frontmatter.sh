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
mkdir -p "$WORKDIR/delegate-local"

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
cp "$FIX/skill-good.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "good frontmatter exits 0"

# 2. Missing frontmatter -> exit 1.
cp "$FIX/skill-no-frontmatter.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "missing frontmatter exits 1"
assert_stderr "no frontmatter" "$out" "missing frontmatter: informative error"

# 3. Name mismatch -> exit 1.
cp "$FIX/skill-name-mismatch.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "name mismatch exits 1"
assert_stderr "wrong-name" "$out" "name mismatch: prints offending name"

# 4. Bad name regex -> exit 1.
cp "$FIX/skill-bad-name.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "bad name regex exits 1"
assert_stderr "regex" "$out" "bad name regex: error mentions regex"

# 5. Missing description -> exit 1.
cp "$FIX/skill-no-description.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "missing description exits 1"
assert_stderr "description" "$out" "missing description: informative error"

# 5a-5e. Length caps (#557): Claude Code truncates description + when_to_use
# at 1,536 chars in the skill listing, so above that fails; above the Agent
# Skills spec's 1,024 only warns.
cp "$FIX/skill-description-1537.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "1537-char description exits 1"
assert_stderr "1536" "$out" "1537-char description: error names the 1536 cap"

cp "$FIX/skill-when-to-use-over-cap.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 1 "$ec" "description 1000 + when_to_use 537 exits 1"
assert_stderr "(1537)" "$out" "combined cap: error reports the summed length"

perl -CSD -e 'print "---\nname: delegate-local\ndescription: ", "\x{2014}" x 1536, "\n---\n"' > "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "1536 multibyte chars exits 0 (cap counts characters, not bytes)"

cp "$FIX/skill-description-1100.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "1100-char description exits 0"
assert_stderr "warning" "$out" "1100-char description: warns above 1024"

cp "$FIX/skill-good.md" "$WORKDIR/delegate-local/SKILL.md"
out=$(bash "$SCRIPT" "$WORKDIR/delegate-local/SKILL.md" 2>&1)
if [[ "$out" == *warning* ]]; then echo "  FAIL  short description does not warn"; fail=$((fail+1))
else echo "  PASS  short description does not warn"; pass=$((pass+1)); fi

# 6. Real SKILL.md must pass.
out=$(bash "$SCRIPT" "$REPO/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "real SKILL.md passes"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
