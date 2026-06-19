#!/usr/bin/env bash
# Unit tests for scripts/fanout-patch.sh. Mocks delegate.sh + apply-and-test.sh
# so the orchestrator's decision logic is exercised without a model or pytest.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/fanout-patch.sh"

pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi; }
assert_contains() { local nd="$1" hs="$2" n="$3"; if [[ "$hs" == *"$nd"* ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (missing '$nd' in '$hs')"; fail=$((fail+1)); fi; }

# A throwaway source-dir (content irrelevant — the mock oracle ignores it, but
# fanout-patch validates the files exist).
make_src() { local d="$1"; printf 'def f():\n    return 0\n' > "$d/source.py"; printf 'from source import f\n\ndef test_f():\n    assert f() == 1\n' > "$d/test_source.py"; }

# Mock delegate.sh: writes a patch whose FIRST line is the verdict word that the
# seed maps to (via $SEEDMAP: "seed verdict" lines; default FAIL), then pads the
# body with '#' * seed so a larger seed = a larger patch (smallest-diff test).
make_mock_delegate() {
  local dir="$1"
  cat > "$dir/delegate.sh" <<'EOF'
#!/usr/bin/env bash
v="FAIL"
if [[ -n "${SEEDMAP:-}" && -f "$SEEDMAP" ]]; then
  m=$(awk -v s="${DELEGATE_SEED:-0}" '$1==s {print $2; exit}' "$SEEDMAP")
  [[ -n "$m" ]] && v="$m"
fi
echo "$v"
pad=""; i=0; while (( i < ${DELEGATE_SEED:-0} )); do pad="$pad#"; i=$((i+1)); done
echo "$pad"
EOF
  chmod +x "$dir/delegate.sh"
}

# Mock apply-and-test.sh: reads the patch (last positional arg), takes its first
# line as the verdict, prints VERDICT/DETAIL and exits with the mapped code.
make_mock_apply() {
  local dir="$1"
  cat > "$dir/apply-and-test.sh" <<'EOF'
#!/usr/bin/env bash
pf=""; for a in "$@"; do pf="$a"; done
v=$(head -1 "$pf" 2>/dev/null); v="${v:-PARSE}"
echo "VERDICT: $v"; echo "DETAIL: mock $v"
case "$v" in PASS) exit 0;; FAIL) exit 1;; PARSE) exit 2;; APPLY) exit 3;; TIMEOUT) exit 4;; REFUSE) exit 5;; *) exit 1;; esac
EOF
  chmod +x "$dir/apply-and-test.sh"
}

run() { # extra-env... -- args...   (returns stdout; sets EC)
  local -a envv=(); while [[ "$1" != "--" ]]; do envv+=("$1"); shift; done; shift
  EC=0
  # bash 3.2-safe empty-array expansion: "${arr[@]}" on an empty array aborts
  # under set -u on macOS bash 3.2, so guard with the +-expansion idiom.
  out=$(env FANOUT_DELEGATE_SH="$BIN/delegate.sh" FANOUT_APPLY_AND_TEST_SH="$BIN/apply-and-test.sh" \
    "${envv[@]+"${envv[@]}"}" bash "$SCRIPT" "$@" 2>/dev/null) || EC=$?
}

BIN=$(mktemp -d); make_mock_delegate "$BIN"; make_mock_apply "$BIN"

# 1. Usage: no source-dir → exit 3.
EC=0; o=$(bash "$SCRIPT" 2>&1) || EC=$?; assert_eq 3 "$EC" "usage: no source-dir -> exit 3"

# 2. Select a passer: seeds 1..5 all FAIL except seed 3 PASS.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '3 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_eq 0 "$EC" "passer: exit 0"
assert_contains "FANOUT_RESULT: PASS_LOCAL" "$out" "passer: PASS_LOCAL outcome"
assert_contains "selected=s3" "$out" "passer: selected seed 3"
rm -rf "$SRC"; rm -f "$MAP"

# 3. Smallest-diff tie-break: seeds 2 and 4 both PASS; seed 2 has the smaller pad.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '2 PASS\n4 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_contains "selected=s2" "$out" "tie-break: smallest diff (seed 2) wins"
rm -rf "$SRC"; rm -f "$MAP"

# 4. Refuse-majority: 3 of 5 REFUSE, none pass → exit 2, no escalation.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 REFUSE\n2 REFUSE\n3 REFUSE\n' > "$MAP"
run SEEDMAP="$MAP" -- "$SRC"
assert_eq 2 "$EC" "refuse-majority: exit 2"
assert_contains "FANOUT_RESULT: REFUSE_MAJORITY" "$out" "refuse-majority: outcome"
rm -rf "$SRC"; rm -f "$MAP"

# 5. Escalation pass: all 5 cheap FAIL, strong (seed 6 = E1) PASSes → exit 0.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '6 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --n 5 --escalate-m 2 "$SRC"
assert_eq 0 "$EC" "escalation: exit 0"
assert_contains "FANOUT_RESULT: PASS_ESCALATED" "$out" "escalation: PASS_ESCALATED outcome"
assert_contains "escalated=1" "$out" "escalation: escalated flag set"
rm -rf "$SRC"; rm -f "$MAP"

# 6. No-pass handback: everything FAILs even after escalation → exit 1, closest attempt.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); : > "$MAP"   # empty map → all FAIL
run SEEDMAP="$MAP" -- --n 3 --escalate-m 1 "$SRC"
assert_eq 1 "$EC" "no-pass: exit 1"
assert_contains "FANOUT_RESULT: NO_PASS" "$out" "no-pass: outcome"
assert_contains "closest attempt" "$out" "no-pass: hands back closest attempt"
rm -rf "$SRC"; rm -f "$MAP"

# 7. Oracle over prose: a sample whose verdict is PASS counts even though its
#    body is irrelevant — the oracle word is authoritative. (seed 1 PASS.)
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_eq 0 "$EC" "oracle-authoritative: PASS verdict wins regardless of body"
rm -rf "$SRC"; rm -f "$MAP"

# 8. Escalation disabled (--escalate-m 0) + all FAIL -> NO_PASS exit 1, no escalation.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); : > "$MAP"
run SEEDMAP="$MAP" -- --n 3 --escalate-m 0 "$SRC"
assert_eq 1 "$EC" "no-escalate: exit 1 when escalation disabled and all fail"
assert_contains "escalated=0" "$out" "no-escalate: escalated flag stays 0"
rm -rf "$SRC"; rm -f "$MAP"

# 9. Closest-attempt rank: a FAIL (s2) outranks APPLY (s1,s3) for the handback patch.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 APPLY\n2 FAIL\n3 APPLY\n' > "$MAP"
run SEEDMAP="$MAP" -- --n 3 --escalate-m 0 "$SRC"
assert_eq 1 "$EC" "rank: exit 1 (no pass)"
assert_contains "selected=s2" "$out" "rank: FAIL (s2) chosen as closest over APPLY"
rm -rf "$SRC"; rm -f "$MAP"

# 10. run() with NO env args exercises the empty-array expansion path under set -u
#     (the bash 3.2 hazard the +-expansion guard fixes).
run -- /nonexistent/dir
assert_eq 3 "$EC" "empty-env run(): bad source-dir -> exit 3 (no unbound-var abort)"

rm -rf "$BIN"
echo ""; echo "fanout-patch tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
