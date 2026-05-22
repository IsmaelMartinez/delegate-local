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

# 12-14. URL_EXTERNAL scope-decision regression (issue #172).
# The decision is to keep the validator file-agnostic but only invoke it on
# SKILL.md from CI and the post-edit hook. Contributor docs under prompts/
# legitimately cite external sources as design-decision evidence. Encode the
# scope decision as tests so a future widening (or an accidental rewiring of
# the gates) trips a regression.

# 12. Validator code is unchanged: pointing it at a file with external URLs
#     still flags. This proves the asymmetry is in the invocation gates, not
#     in the validator logic.
out=$(ALLOW_FILE="$EMPTY_ALLOW" bash "$SCRIPT" "$REPO/prompts/README.md" 2>&1); ec=$?
assert_exit 1 "$ec" "prompts/README.md flags URL_EXTERNAL when validator is pointed at it directly"
assert_contains "URL_EXTERNAL" "$out" "prompts/README.md hit names URL_EXTERNAL"

# 13. CI workflow only calls the validator with SKILL.md as the argument.
# Grep for the invocation and assert the arg list is exactly SKILL.md.
CI_INVOCATIONS=$(grep -E 'validate-skill-content\.sh' "$REPO/.github/workflows/ci.yml" | grep -v '^[[:space:]]*#' || true)
if [[ -z "$CI_INVOCATIONS" ]]; then
  echo "  FAIL  CI workflow has no validate-skill-content.sh invocation"; fail=$((fail+1))
else
  bad=$(printf '%s\n' "$CI_INVOCATIONS" | grep -vE 'validate-skill-content\.sh SKILL\.md[[:space:]]*$' || true)
  if [[ -z "$bad" ]]; then
    echo "  PASS  CI workflow only invokes validate-skill-content.sh on SKILL.md"
    pass=$((pass+1))
  else
    echo "  FAIL  CI workflow invokes validate-skill-content.sh on a file other than SKILL.md:"
    printf '%s\n' "$bad" | sed 's/^/        /'
    fail=$((fail+1))
  fi
fi

# 14. Post-edit hook only calls the validator inside the *SKILL.md case branch.
# Parse the case statement: the validator must appear under the *SKILL.md)
# pattern and nowhere else.
HOOK="$REPO/.claude/hooks/post-edit-validate.sh"
HOOK_INVOCATIONS=$(grep -nE 'validate-skill-content\.sh' "$HOOK" | grep -v '^[[:space:]]*#' || true)
if [[ -z "$HOOK_INVOCATIONS" ]]; then
  echo "  FAIL  post-edit hook has no validate-skill-content.sh invocation"; fail=$((fail+1))
else
  # Extract line numbers and verify each falls between the *SKILL.md) and the
  # next ;; in the case statement.
  skill_open=$(grep -nE '\*SKILL\.md\)' "$HOOK" | head -1 | cut -d: -f1)
  if [[ -z "$skill_open" ]]; then
    echo "  FAIL  post-edit hook lacks a *SKILL.md) case branch"; fail=$((fail+1))
  else
    skill_close=$(awk -v start="$skill_open" 'NR > start && /;;/ {print NR; exit}' "$HOOK")
    bad=""
    while IFS=: read -r ln _; do
      if (( ln <= skill_open || ln >= skill_close )); then
        bad="$bad$ln "
      fi
    done <<<"$HOOK_INVOCATIONS"
    if [[ -z "$bad" ]]; then
      echo "  PASS  post-edit hook only invokes validate-skill-content.sh inside *SKILL.md) branch"
      pass=$((pass+1))
    else
      echo "  FAIL  post-edit hook invokes validate-skill-content.sh outside *SKILL.md) branch at line(s): $bad"
      fail=$((fail+1))
    fi
  fi
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
