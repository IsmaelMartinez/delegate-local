#!/usr/bin/env bash
# Unit tests for scripts/onboard.sh. Drives the confirm-or-edit loop through the
# DELEGATE_ONBOARD_ASSUME_TTY=1 seam (a real pty can't run in CI) against a
# throwaway git repo with a known commit corpus and a mocked `ollama` on a
# restricted PATH, pinning the print-only no-write contract, the write/backup/
# decline branches, input validation, and the round-trip through load-flavor.sh.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/onboard.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0
assert_eq() { if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1)); else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi; }
assert_contains() { case "$2" in *"$1"*) echo "  PASS  $3"; pass=$((pass+1));; *) echo "  FAIL  $3 (missing '$1')"; fail=$((fail+1));; esac; }
assert_absent() { case "$2" in *"$1"*) echo "  FAIL  $3 (unexpected '$1')"; fail=$((fail+1));; *) echo "  PASS  $3"; pass=$((pass+1));; esac; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mock ollama so init.sh's environment probe succeeds deterministically.
mock="$tmp/bin"; mkdir -p "$mock"
cat > "$mock/ollama" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  echo "NAME                  ID    SIZE   MODIFIED"
  echo "qwen3.6:35b-a3b-q8_0  abc   20GB   now"
fi
EOF
chmod +x "$mock/ollama"

# Throwaway corpus repo: subject lengths 7,7,9,10,14,17 -> P90 index 5 -> max 14;
# types feat x3 + fix x2 (docs appears once and is dropped by the >=2 rule).
# feat outnumbers fix so the frequency ordering is deterministic — a 2/2 tie
# falls into sort(1)'s unstable last-resort comparison.
corpus="$tmp/corpus"; mkdir -p "$corpus"
# Neutralise the developer's global/system git config (gpg signing, hooks)
# so the corpus commits are deterministic on any machine, not just CI.
ggit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$corpus" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
ggit init -q -b main
gc() { ggit commit -q --allow-empty -m "$1"; }
gc "feat: aaaa"          # 10
gc "feat: bbbbbbbb"      # 14
gc "feat: zzz"           # 9
gc "fix: cc"             # 7
gc "fix: dddddddddddd"   # 17
gc "docs: e"             # 7

# run_onboard <answers> <profile> <config> [extra env assignments...]
run_onboard() {
  local answers="$1" profile="$2" config="$3"; shift 3
  ( cd "$corpus" && printf '%b' "$answers" | \
    env PATH="$mock:$SAFE_PATH" DELEGATE_ONBOARD_ASSUME_TTY=1 \
        DELEGATE_LOCAL_PROFILE="$profile" DELEGATE_LOCAL_CONFIG="$config" "$@" \
        bash "$SCRIPT" 2>&1 )
}

# --- T1: non-interactive -> print-only, nothing written ----------------------
out=$( cd "$corpus" && env PATH="$mock:$SAFE_PATH" \
  DELEGATE_LOCAL_PROFILE="$tmp/t1p.sh" DELEGATE_LOCAL_CONFIG="$tmp/t1c.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T1: print-only exits 0"
assert_contains "routing override candidate" "$out" "T1: prints the config fragment"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$out" "T1: prints the derived subject max"
assert_contains 'FLAVOR_COMMIT_TYPES="feat, fix"' "$out" "T1: prints the derived type list"
assert_contains "wrote nothing" "$out" "T1: says it wrote nothing"
[[ ! -f "$tmp/t1p.sh" && ! -f "$tmp/t1c.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T1: neither target file created"

# --- T2: accept-all -> both files written, mode 600, derived values ----------
out=$(run_onboard '\n\ny\n' "$tmp/t2p.sh" "$tmp/t2c.sh"); ec=$?
assert_eq "0" "$ec" "T2: accept-all exits 0"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$(cat "$tmp/t2p.sh")" "T2: profile carries derived subject max"
assert_contains 'FLAVOR_COMMIT_TYPES="feat, fix"' "$(cat "$tmp/t2p.sh")" "T2: profile carries derived types"
assert_contains 'case "$tier" in' "$(cat "$tmp/t2c.sh")" "T2: config carries the routing override"
# perl for the mode read — GNU stat treats -f as "filesystem status" and
# SUCCEEDS with the wrong semantics, so a BSD-first || fallback never fires.
mode=$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$tmp/t2p.sh")
assert_eq "600" "$mode" "T2: profile written mode 600"

# --- T3: typed override replaces the prefill ---------------------------------
out=$(run_onboard '60\n\nn\n' "$tmp/t3p.sh" "$tmp/t3c.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=60" "$(cat "$tmp/t3p.sh")" "T3: typed subject max written"
[[ ! -f "$tmp/t3c.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T3: declined config not written"

# --- T4: existing profile + decline overwrite -> untouched, no backup --------
echo "FLAVOR_COMMIT_SUBJECT_MAX=99" > "$tmp/t4p.sh"
out=$(run_onboard '\n\nn\nn\n' "$tmp/t4p.sh" "$tmp/t4c.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=99" "$(cat "$tmp/t4p.sh")" "T4: declined overwrite leaves profile untouched"
assert_contains "kept existing" "$out" "T4: explains the decline"
[[ -z "$(ls "$tmp"/t4p.sh.bak.* 2>/dev/null)" ]] && r=ok || r=bak
assert_eq "ok" "$r" "T4: no backup created on decline"

# --- T5: existing profile + confirm -> backup holds old, target holds new ----
echo "FLAVOR_COMMIT_SUBJECT_MAX=99" > "$tmp/t5p.sh"
out=$(run_onboard '\n\ny\nn\n' "$tmp/t5p.sh" "$tmp/t5c.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$(cat "$tmp/t5p.sh")" "T5: confirmed overwrite wrote new values"
bak=$(ls "$tmp"/t5p.sh.bak.* 2>/dev/null | head -1)
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=99" "$(cat "$bak")" "T5: backup preserves the old profile"

# --- T6: quit at the first prompt -> nothing written -------------------------
out=$(run_onboard 'q\n' "$tmp/t6p.sh" "$tmp/t6c.sh"); ec=$?
assert_eq "0" "$ec" "T6: quit exits 0"
assert_contains "nothing written" "$out" "T6: quit says nothing written"
[[ ! -f "$tmp/t6p.sh" && ! -f "$tmp/t6c.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T6: quit created no files"

# --- T7: skip both keys -> profile not written, config still offered ---------
out=$(run_onboard 's\ns\nn\n' "$tmp/t7p.sh" "$tmp/t7c.sh")
assert_contains "profile not written" "$out" "T7: skip-both explains no profile"
[[ ! -f "$tmp/t7p.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T7: skip-both wrote no profile"

# --- T8: non-git cwd -> shipped defaults as prefill, still exits 0 -----------
empty="$tmp/empty"; mkdir -p "$empty"
out=$( cd "$empty" && env PATH="$mock:$SAFE_PATH" \
  DELEGATE_LOCAL_PROFILE="$tmp/t8p.sh" DELEGATE_LOCAL_CONFIG="$tmp/t8c.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T8: non-git cwd exits 0"
assert_contains "fall back to shipped defaults" "$out" "T8: explains the fallback"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=72" "$out" "T8: shipped default becomes the prefill"

# --- T9: no ollama on PATH -> env section skipped, flavor still offered ------
out=$( cd "$corpus" && env PATH="$SAFE_PATH" \
  DELEGATE_LOCAL_PROFILE="$tmp/t9p.sh" DELEGATE_LOCAL_CONFIG="$tmp/t9c.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T9: no-ollama exits 0"
assert_contains "environment probe skipped" "$out" "T9: explains the skipped probe"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$out" "T9: flavor candidate still printed"
assert_absent "routing override candidate" "$out" "T9: no config fragment without ollama"

# --- T10: invalid edit re-prompts, then a valid retry is accepted ------------
out=$(run_onboard 'abc\n55\n\nn\n' "$tmp/t10p.sh" "$tmp/t10c.sh")
assert_contains "invalid value" "$out" "T10: rejects the non-numeric edit"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=55" "$(cat "$tmp/t10p.sh")" "T10: accepts the valid retry"

# --- T11: round-trip — written profile drives load-flavor.sh -----------------
out=$(env DELEGATE_LOCAL_PROFILE="$tmp/t2p.sh" bash "$REPO/scripts/load-flavor.sh")
assert_contains "flavor_commit_subject_max=14" "$out" "T11: load-flavor resolves the written subject max"
assert_contains "flavor_commit_types=feat, fix" "$out" "T11: load-flavor resolves the written types"

# --- T12: usage error on an unknown flag --------------------------------------
out=$(bash "$SCRIPT" --bogus 2>&1); ec=$?
assert_eq "2" "$ec" "T12: unknown flag -> exit 2"
assert_contains "unknown arg" "$out" "T12: names the bad flag"

# --- T13: an unterminated final answer (EOF, no newline) is still honoured ----
# read returns non-zero at EOF but fills the variable; the q/n fallback must
# only fire on a truly empty read.
out=$(run_onboard '\n\ny' "$tmp/t13p.sh" "$tmp/t13c.sh")
assert_contains 'case "$tier" in' "$(cat "$tmp/t13c.sh")" "T13: config written from an unterminated trailing y"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
