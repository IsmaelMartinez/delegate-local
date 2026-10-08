#!/usr/bin/env bash
# Guard for #654: living files name the tier's role ("the prose-tier model"),
# never the model pick-model.sh currently ships, so a model switch edits
# routing and not every doc, recipe and test. The name searched for is the
# prose tier's first shipped preference (PROSE_PREF, from assert.sh), matched
# as a fixed string ignoring case, so the guard follows the shipped routing.
# The paths below may name it: routing itself, the tests that assert shipped
# routing, per-model shipped calibration data, and history (ADRs, calibration
# logs, the changelog, dated read-outs and captured fixture diffs), which keep
# naming whichever model they measured.

set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

ALLOWED_RE='^(scripts/pick-model\.sh|tests/run-tests\.sh|scripts/lib/verify-thresholds\.tsv|docs/adr/|docs/calibration/|CHANGELOG\.md|docs/verify\.md|docs/model-swap\.md|tests/fixtures/)'

echo "== model names stay in routing, routing tests, calibration data and history =="
assert_true "the shipped prose list has a first preference to search for" test -n "$PROSE_PREF"
offenders=$(git -C "$REPO" grep -liF -e "$PROSE_PREF" -- . | grep -vE "$ALLOWED_RE" || true)
assert_eq "" "$offenders" "no living file outside the allowlist names the shipped prose model ($PROSE_PREF)"

echo "== the fixture prose model resolves through the shipped list =="
mock=$(mktemp -d)
mock_curl "$mock"
got=$(env -i PATH="$mock:$SAFE_PATH" HOME="$HOME" DELEGATE_LOCAL_CONFIG=/dev/null \
  DELEGATE_BASE_URL=http://localhost:8080/v1 bash "$REPO/scripts/pick-model.sh" prose 2>/dev/null)
assert_eq "$PROSE_MODEL" "$got" "PROSE_MODEL ($PROSE_MODEL) is what the prose tier resolves"

finish
