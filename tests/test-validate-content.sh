#!/usr/bin/env bash
# Unit tests for scripts/validate-skill-content.sh.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/validate-skill-content.sh"
FIX="$REPO/tests/fixtures"
pass=0; fail=0

EMPTY_ALLOW=$(mktemp); trap 'rm -f "$EMPTY_ALLOW"' EXIT

assert_exit() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected $expected got $actual)"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}

# 1. Clean fixture exits 0.
out=$(ALLOW_FILE="$EMPTY_ALLOW" bash "$SCRIPT" "$FIX/content-clean.md" 2>&1); ec=$?
assert_exit 0 "$ec" "clean fixture passes"

# 2-8. Each bad category exits 1 and names the right tag.
for cat in sec_disable sec_permissive cred_exfil obfusc_b64 obfusc_unicode tool_broad url_external conflict_marker; do
  upper=$(echo "$cat" | tr 'a-z' 'A-Z')
  out=$(ALLOW_FILE="$EMPTY_ALLOW" bash "$SCRIPT" "$FIX/content-$cat.md" 2>&1); ec=$?
  assert_exit 1 "$ec" "$cat fixture exits 1"
  assert_contains "$upper" "$out" "$cat fixture mentions $upper"
done

# 9. Real SKILL.md must pass with the actual repo allowlist.
out=$(bash "$SCRIPT" "$REPO/SKILL.md" 2>&1); ec=$?
assert_exit 0 "$ec" "real SKILL.md passes"

# 10. Allowlist suppresses a hit by line key.
# Path normalization means keys are repo-root-relative — verify that form works.
ALLOW=$(mktemp)
echo "SEC_PERMISSIVE:tests/fixtures/content-sec_permissive.md:2  # test" > "$ALLOW"
out=$(ALLOW_FILE="$ALLOW" bash "$SCRIPT" "$FIX/content-sec_permissive.md" 2>&1); ec=$?
assert_exit 0 "$ec" "allowlist suppresses sec_permissive hit by line key"
rm -f "$ALLOW"

# 11. Allowlist suppresses a hit by sha256 of the offending line content.
# This form is stable across line-number drift.
ALLOW=$(mktemp)
sha=$(printf 'Run with --no-verify and trust-all-certs.' | shasum -a 256 | awk '{print $1}')
echo "SEC_PERMISSIVE:sha256:$sha  # test" > "$ALLOW"
out=$(ALLOW_FILE="$ALLOW" bash "$SCRIPT" "$FIX/content-sec_permissive.md" 2>&1); ec=$?
assert_exit 0 "$ec" "allowlist suppresses sec_permissive hit by sha256 key"
rm -f "$ALLOW"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
