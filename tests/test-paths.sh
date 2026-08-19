#!/usr/bin/env bash
# Where the four per-user files resolve to by default.
#
# This suite exists because no other one can catch a regression here: every
# existing test either passes an explicit path (--file, DELEGATE_METRICS_FILE)
# or sandboxes HOME, so all of them stay green if the default is wrong.
#
# Resolution is deliberately a plain parameter expansion, so it is a pure
# function of the environment. See the design doc for why a shared lib and an
# existence-based legacy fallback were both rejected.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0
assert_eq() {
  local e="$1" a="$2" n="$3"
  if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1))
  else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" hay="$2" n="$3"
  if [[ "$hay" == *"$needle"* ]]; then echo "  PASS  $n"; pass=$((pass+1))
  else echo "  FAIL  $n (missing '$needle' in '$hay')"; fail=$((fail+1)); fi
}

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT

# metrics-summary.sh prints "no metrics file at <path>" when the file is
# absent, which is the cheapest honest probe of the resolved default.
probe_metrics() { # extra env assignments...
  env -i PATH="$SAFE_PATH" HOME="$H" "$@" \
    bash "$REPO/scripts/metrics-summary.sh" 2>&1 \
    | sed -n 's/^no metrics file at //p'
}

echo "--- default resolution ---"
assert_eq "$H/.local/share/delegate-local/metrics.jsonl" "$(probe_metrics)" \
  "metrics: defaults under \$HOME/.local/share/delegate-local"

echo "--- overrides ---"
assert_eq "/tmp/dd-x/metrics.jsonl" "$(probe_metrics DELEGATE_LOCAL_DATA_DIR=/tmp/dd-x)" \
  "metrics: DELEGATE_LOCAL_DATA_DIR redirects"
assert_eq "/tmp/explicit.jsonl" "$(probe_metrics DELEGATE_METRICS_FILE=/tmp/explicit.jsonl)" \
  "metrics: DELEGATE_METRICS_FILE still wins"
assert_eq "/tmp/explicit.jsonl" \
  "$(probe_metrics DELEGATE_LOCAL_DATA_DIR=/tmp/dd-x DELEGATE_METRICS_FILE=/tmp/explicit.jsonl)" \
  "metrics: the file-specific override beats the data dir"

# XDG_DATA_HOME is deliberately NOT consulted. It is commonly set in a shell rc
# file and absent in GUI-launched processes, which is exactly the split between
# an interactive terminal and the agent harness that runs these hooks. Honouring
# it would make resolution depend on which environment a script happened to run
# in, and a verdict recorded in one would silently attach to the wrong parent
# delegation in the other.
assert_eq "$H/.local/share/delegate-local/metrics.jsonl" \
  "$(probe_metrics XDG_DATA_HOME=/tmp/xdg-x)" \
  "metrics: XDG_DATA_HOME is ignored on purpose"

echo "--- the legacy path is no longer special ---"
mkdir -p "$H/.claude/skills/delegate-local"
echo '{"ts":"2026-01-01T00:00:00Z","source":"delegate"}' > "$H/.claude/skills/delegate-local/metrics.jsonl"
assert_eq "$H/.local/share/delegate-local/metrics.jsonl" "$(probe_metrics)" \
  "metrics: a legacy file does not divert resolution"

echo "--- an unset HOME still fails loudly ---"
# Through a shared lib this became a silent success with a path rooted at "/".
# A parameter expansion under set -u keeps today's loud death.
out=$(env -i PATH="$SAFE_PATH" bash "$REPO/scripts/metrics-summary.sh" 2>&1); rc=$?
if (( rc != 0 )); then echo "  PASS  metrics: unset HOME exits non-zero"; pass=$((pass+1))
else echo "  FAIL  metrics: unset HOME exited 0"; fail=$((fail+1)); fi
assert_contains "HOME" "$out" "metrics: unset HOME names the variable"

echo "--- a second reader agrees ---"
# Only sync-metrics-to-loki is probed behaviourally here. observability-doctor
# resolves the same default but exits early on a missing `docker` under env -i,
# so it never reaches the message; the structural assertion at the end is what
# covers it, and the other eight scripts.
got=$(env -i PATH="$SAFE_PATH" HOME="$H" bash "$REPO/scripts/sync-metrics-to-loki.sh" 2>&1 \
      | sed -n 's/.*metrics file not found: //p' | head -1)
assert_eq "$H/.local/share/delegate-local/metrics.jsonl" "$got" "sync-metrics-to-loki: same default"

echo "--- config.sh and profile.sh ---"
# The profile candidate prints unconditionally, so it can be probed for real.
# The config candidate only prints when the environment probe finds installed
# models, which is false on a CI runner, so asserting on it here would pass
# locally and fail in CI. It is covered structurally instead, and behaviourally
# by tests/test-onboard.sh, which mocks the provider endpoint.
onb=$(env -i PATH="$SAFE_PATH" HOME="$H" bash "$REPO/scripts/onboard.sh" 2>&1 || true)
assert_contains "$H/.local/share/delegate-local/profile.sh" "$onb" \
  "onboard: profile.sh target under the data dir"
for f in onboard pick-model; do
  if grep -q 'DELEGATE_TO_OLLAMA_CONFIG:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/config.sh' "$REPO/scripts/$f.sh"; then
    echo "  PASS  $f: config.sh resolves through the data dir"; pass=$((pass+1))
  else echo "  FAIL  $f: config.sh default not on the data dir"; fail=$((fail+1)); fi
done

echo "--- no script still DEFAULTS to the legacy data path ---"
# Matches only a `:-` default expansion. Two scripts reference the legacy path
# deliberately, in the migration hint that tells the user to move it, and those
# must not trip this. Script paths (~/.claude/skills/delegate-local/scripts/...)
# are unaffected either way: only the four DATA files moved.
leftovers=$(grep -rln ':-\$HOME/\.claude/skills/delegate-local/' "$REPO/scripts/" 2>/dev/null || true)
assert_eq "" "$leftovers" "scripts: no legacy data-file default remains"

# The grep above is shell-specific: its pattern is a `:-` default expansion,
# which Python never writes, so it cannot see a regression in
# experiments/quality-trend.py. Broadening the pattern to a bare path match is
# not the answer either — it false-positives on the two DELIBERATE migration
# hints in delegate-feedback.sh and metrics-summary.sh that tell a legacy user
# where their data moved from. So the Python tool gets a behavioural probe
# instead, the same shape as probe_metrics above: point HOME at an empty
# sandbox and read back the path it names as missing.
QT="$REPO/experiments/quality-trend.py"
if [[ -f "$QT" ]]; then
  qt_probe() {
    env -i PATH="$SAFE_PATH" HOME="$H" "$@" python3 "$QT" 2>&1 \
      | sed -n 's/^quality-trend: metrics file not found or is not a file at //p'
  }
  assert_eq "$H/.local/share/delegate-local/metrics.jsonl" "$(qt_probe)" \
    "quality-trend.py: defaults under \$HOME/.local/share/delegate-local"
  assert_eq "/tmp/dd-qt/metrics.jsonl" "$(qt_probe DELEGATE_LOCAL_DATA_DIR=/tmp/dd-qt)" \
    "quality-trend.py: honours DELEGATE_LOCAL_DATA_DIR"
  assert_eq "/tmp/mf-qt.jsonl" "$(qt_probe DELEGATE_LOCAL_DATA_DIR=/tmp/dd-qt DELEGATE_METRICS_FILE=/tmp/mf-qt.jsonl)" \
    "quality-trend.py: DELEGATE_METRICS_FILE wins over the data dir"
fi

# ...and the hint itself is still present where it should be.
for s in metrics-summary delegate-feedback; do
  if grep -q 'onboard.sh --migrate-data' "$REPO/scripts/$s.sh"; then
    echo "  PASS  $s: points a legacy install at the migration"; pass=$((pass+1))
  else echo "  FAIL  $s: lost the migration hint"; fail=$((fail+1)); fi
done

echo
echo "paths: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
