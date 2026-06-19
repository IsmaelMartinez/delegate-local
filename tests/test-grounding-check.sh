#!/usr/bin/env bash
# Unit tests for scripts/grounding-check.sh — the faithfulness grounding check.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GC="$REPO/scripts/grounding-check.sh"
pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi; }
assert_contains() { local nd="$1" hs="$2" n="$3"; if [[ "$hs" == *"$nd"* ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (missing '$nd')"; fail=$((fail+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A realistic diff with several distinctive identifiers.
cat > "$tmp/diff.txt" <<'EOF'
diff --git a/auth.py b/auth.py
--- a/auth.py
+++ b/auth.py
@@ -10,6 +10,9 @@ def login(user, pw):
     if not user:
         raise ValueError("no user")
+    if failed_attempts(user) >= 5:
+        raise LockedError(user)
     return check(user, pw)
EOF

# 1. Faithful output -> GROUNDED, exit 0.
EC=0
out=$(printf 'fix(auth): lock account after failed login attempts\n\nRaise LockedError once failed_attempts hits five.' | bash "$GC" --input "$tmp/diff.txt") || EC=$?
assert_eq 0 "$EC" "faithful output -> exit 0"
assert_contains "GROUNDED" "$out" "faithful output -> GROUNDED"

# 2. Regurgitated/drifted output (unrelated topic) -> UNGROUNDED, exit 1.
EC=0
out=$(printf 'feat: handle stale lock file when daemon crashes\n\nThe fix invalidates the lock file when a daemon crashes.' | bash "$GC" --input "$tmp/diff.txt") || EC=$?
assert_eq 1 "$EC" "drifted output -> exit 1"
assert_contains "UNGROUNDED" "$out" "drifted output -> UNGROUNDED"

# 3. Distinctive-identifier rule: an output that only shares the coincidental
#    common word "lock" (from the diff's intent, not a code symbol) must NOT
#    count as grounded — the naive version wrongly passed this as GROUNDED.
EC=0
out=$(printf 'chore: tidy up the lock file handling in the build' | bash "$GC" --input "$tmp/diff.txt") || EC=$?
assert_eq 1 "$EC" "lone common-word overlap -> still UNGROUNDED"
assert_contains "distinctive=0" "$out" "lone common-word overlap -> distinctive=0"

# 4. Grounded by a distinctive code symbol.
EC=0
out=$(printf 'feat: raise LockedError after too many failed_attempts' | bash "$GC" --input "$tmp/diff.txt") || EC=$?
assert_eq 0 "$EC" "distinctive symbol match -> GROUNDED exit 0"

# 5. Grounded by the filename.
EC=0
out=$(printf 'refactor: simplify the login flow in auth.py' | bash "$GC" --input "$tmp/diff.txt") || EC=$?
assert_eq 0 "$EC" "filename match -> GROUNDED exit 0"

# 6. SKIP when the input carries too few distinctive identifiers to judge.
cat > "$tmp/trivial.txt" <<'EOF'
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1 +1 @@
-1
+2
EOF
EC=0
out=$(printf 'feat: completely unrelated commit message about networking' | bash "$GC" --input "$tmp/trivial.txt") || EC=$?
assert_eq 0 "$EC" "too-few-identifiers -> SKIP exit 0 (never a false positive)"
assert_contains "SKIP" "$out" "too-few-identifiers -> SKIP"

# 7. --min-idents override is honoured.
EC=0
out=$(printf 'unrelated text' | bash "$GC" --input "$tmp/diff.txt" --min-idents 99) || EC=$?
assert_eq 0 "$EC" "high --min-idents forces SKIP"
assert_contains "SKIP" "$out" "high --min-idents -> SKIP"

# 8. Usage error when input file is missing.
EC=0
out=$(printf 'x' | bash "$GC" --input "$tmp/nope.txt" 2>&1) || EC=$?
assert_eq 2 "$EC" "missing input file -> exit 2"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
