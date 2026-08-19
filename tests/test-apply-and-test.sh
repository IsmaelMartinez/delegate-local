#!/usr/bin/env bash
# Unit tests for scripts/apply-and-test.sh.
# Builds tiny synthetic fixtures (source.py + test_source.py) and synthetic
# patch files exercising every verdict path: PASS, FAIL, PARSE, APPLY (empty,
# unmatched, ambiguous), REFUSE, plus usage errors.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/apply-and-test.sh"

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
  else echo "  FAIL  $name (missing '$needle' in '$haystack')"; fail=$((fail+1)); fi
}

# Build a fixture with a single function the test asserts on.
make_fixture() {
  local dir="$1"
  cat > "$dir/source.py" <<'PY'
def add(a, b):
    return a + b
PY
  cat > "$dir/test_source.py" <<'PY'
from source import add

def test_add_positive():
    assert add(1, 2) == 3

def test_add_zero():
    assert add(0, 0) == 0
PY
}

# 1. usage: missing args → exit 6.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 6 "$EC" "missing args -> exit 6"
assert_contains "usage:" "$out" "missing args -> usage line"

# 2. usage: bad flag → exit 6.
EC=0
out=$(bash "$SCRIPT" --bogus a b 2>&1) || EC=$?
assert_eq 6 "$EC" "bad flag -> exit 6"
assert_contains "unknown flag" "$out" "bad flag -> unknown-flag message"

# 3. usage: source-dir missing → exit 6.
EC=0
out=$(bash "$SCRIPT" /nonexistent/dir somepatch 2>&1) || EC=$?
assert_eq 6 "$EC" "missing source-dir -> exit 6"
assert_contains "not a directory" "$out" "missing source-dir -> error message"

# 4. usage: source.py absent in source-dir → exit 6.
tmp=$(mktemp -d); src=$(mktemp -d)
echo "x" > "$tmp/patch.txt"
EC=0
out=$(bash "$SCRIPT" "$src" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 6 "$EC" "missing source.py -> exit 6"
assert_contains "missing source.py" "$out" "missing source.py -> error message"
rm -rf "$tmp" "$src"

# 5. PASS: minimal valid patch + matching tests.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    # cosmetic: identical behaviour
    return a + b
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "PASS: exit 0"
assert_contains "VERDICT: PASS" "$out" "PASS: verdict line"
rm -rf "$tmp"

# 6. FAIL: patch breaks the function so tests fail.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
    return a + b
=======
    return a - b
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 1 "$EC" "FAIL: exit 1"
assert_contains "VERDICT: FAIL" "$out" "FAIL: verdict line"
assert_contains "DETAIL:" "$out" "FAIL: detail emitted"
rm -rf "$tmp"

# 7. PARSE: no SEARCH/REPLACE blocks at all.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
sorry, I cannot help with this task. let me know if there's something else.
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 2 "$EC" "PARSE: exit 2"
assert_contains "VERDICT: PARSE" "$out" "PARSE: verdict line"
rm -rf "$tmp"

# 8. APPLY (empty SEARCH): an empty SEARCH block is rejected.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH

=======
something
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 3 "$EC" "APPLY-empty: exit 3"
assert_contains "empty SEARCH" "$out" "APPLY-empty: detail mentions empty SEARCH"
rm -rf "$tmp"

# 9. APPLY (not found): SEARCH not in source.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def subtract(a, b):
    return a - b
=======
def subtract(a, b):
    return b - a
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 3 "$EC" "APPLY-notfound: exit 3"
assert_contains "SEARCH not found" "$out" "APPLY-notfound: detail mentions not found"
rm -rf "$tmp"

# 10. APPLY (ambiguous): SEARCH matches twice.
tmp=$(mktemp -d)
cat > "$tmp/source.py" <<'PY'
x = 1
x = 1
PY
cat > "$tmp/test_source.py" <<'PY'
def test_pass():
    assert True
PY
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
x = 1
=======
x = 2
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 3 "$EC" "APPLY-ambiguous: exit 3"
assert_contains "ambiguous (2 matches)" "$out" "APPLY-ambiguous: detail mentions match count"
rm -rf "$tmp"

# 11. REFUSE: no blocks but a REFUSE: line.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
REFUSE: this change would break callers in unrelated modules.
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 5 "$EC" "REFUSE: exit 5"
assert_contains "VERDICT: REFUSE" "$out" "REFUSE: verdict line"
rm -rf "$tmp"

# 12. REFUSE: case-insensitive recognition (lowercase "refuse:").
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
refuse: lower case still counts
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 5 "$EC" "REFUSE lower: exit 5"
assert_contains "VERDICT: REFUSE" "$out" "REFUSE lower: verdict line"
rm -rf "$tmp"

# 13. Patch from stdin (-) is honoured.
tmp=$(mktemp -d)
make_fixture "$tmp"
EC=0
out=$(printf '<<<<<<< SEARCH\ndef add(a, b):\n    return a + b\n=======\ndef add(a, b):\n    return a + b\n>>>>>>> REPLACE\n' | bash "$SCRIPT" "$tmp" - 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin patch: exit 0"
assert_contains "VERDICT: PASS" "$out" "stdin patch: PASS verdict"
rm -rf "$tmp"

# 14. --out flag: patched copy written to chosen dir.
tmp=$(mktemp -d); out=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
    return a + b
=======
    return a + b  # patched
>>>>>>> REPLACE
EOF
EC=0
bash "$SCRIPT" --out "$out" "$tmp" "$tmp/patch.txt" >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "--out: exit 0"
[[ -f "$out/source.py" ]] && pass=$((pass+1)) && echo "  PASS  --out: source.py written" || { fail=$((fail+1)); echo "  FAIL  --out: source.py missing"; }
grep -q "patched" "$out/source.py" 2>/dev/null && pass=$((pass+1)) && echo "  PASS  --out: patch applied to written file" || { fail=$((fail+1)); echo "  FAIL  --out: patch not in written file"; }
rm -rf "$tmp" "$out"

# 15. --test-script flag honoured.
tmp=$(mktemp -d)
make_fixture "$tmp"
mv "$tmp/test_source.py" "$tmp/test_alt.py"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" --test-script test_alt.py "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "--test-script: exit 0"
assert_contains "VERDICT: PASS" "$out" "--test-script: PASS"
rm -rf "$tmp"

# 16. --source-name flag honoured.
tmp=$(mktemp -d)
mv_fixture() {
  cat > "$tmp/lib.py" <<'PY'
def add(a, b):
    return a + b
PY
  cat > "$tmp/test_source.py" <<'PY'
from lib import add
def test_add():
    assert add(2, 2) == 4
PY
}
mv_fixture
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b  # ok
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" --source-name lib.py "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "--source-name: exit 0"
assert_contains "VERDICT: PASS" "$out" "--source-name: PASS"
rm -rf "$tmp"

# 17. Multiple SEARCH/REPLACE blocks applied in order.
tmp=$(mktemp -d)
cat > "$tmp/source.py" <<'PY'
def add(a, b):
    return a + b

def sub(a, b):
    return a - b
PY
cat > "$tmp/test_source.py" <<'PY'
from source import add, sub

def test_both():
    assert add(1, 2) == 3
    assert sub(5, 3) == 2
PY
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b  # patched
>>>>>>> REPLACE

<<<<<<< SEARCH
def sub(a, b):
    return a - b
=======
def sub(a, b):
    return a - b  # patched
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "multi-block: exit 0"
assert_contains "VERDICT: PASS" "$out" "multi-block: PASS"
rm -rf "$tmp"

# 18. APPLY-second-block: first applies, second has no match → APPLY for block 2.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b
>>>>>>> REPLACE

<<<<<<< SEARCH
def nonexistent():
    pass
=======
def nonexistent():
    return 1
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 3 "$EC" "multi-block-second-fails: exit 3"
assert_contains "block 2:" "$out" "multi-block-second-fails: detail names block 2"
rm -rf "$tmp"

# 19. Verdict line is on stdout (not stderr) so callers can pipe.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b
>>>>>>> REPLACE
EOF
stdout_only=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>/dev/null)
assert_contains "VERDICT: PASS" "$stdout_only" "stdout: VERDICT printed to stdout"
rm -rf "$tmp"

# 20. Sibling-file dependency: tests that import a helper module sitting next
# to source.py must still find it after patching. Regression test for the
# pre-fix behaviour where only test_source.py was copied to out_dir.
tmp=$(mktemp -d)
cat > "$tmp/source.py" <<'PY'
from helper import bump

def add(a, b):
    return bump(a + b)
PY
cat > "$tmp/helper.py" <<'PY'
def bump(x):
    return x + 0
PY
cat > "$tmp/test_source.py" <<'PY'
from source import add

def test_add_uses_helper():
    assert add(1, 2) == 3
PY
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return bump(a + b)
=======
def add(a, b):
    return bump(a + b)  # patched
>>>>>>> REPLACE
EOF
EC=0
out=$(bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "sibling-file: exit 0 (helper module copied alongside)"
assert_contains "VERDICT: PASS" "$out" "sibling-file: PASS"
rm -rf "$tmp"

# 21. APPLY_AND_TEST_PYTHON env var pins the interpreter.
tmp=$(mktemp -d)
make_fixture "$tmp"
cat > "$tmp/patch.txt" <<'EOF'
<<<<<<< SEARCH
def add(a, b):
    return a + b
=======
def add(a, b):
    return a + b
>>>>>>> REPLACE
EOF
real_py=$(command -v python3)
EC=0
out=$(APPLY_AND_TEST_PYTHON="$real_py" bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "APPLY_AND_TEST_PYTHON: env override exits 0"
EC=0
out=$(APPLY_AND_TEST_PYTHON="/no/such/python" bash "$SCRIPT" "$tmp" "$tmp/patch.txt" 2>&1) || EC=$?
assert_eq 6 "$EC" "APPLY_AND_TEST_PYTHON: bogus path -> exit 6"
assert_contains "python3 not on PATH" "$out" "APPLY_AND_TEST_PYTHON: bogus path -> error message"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
