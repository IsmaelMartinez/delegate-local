#!/usr/bin/env bash
# Unit tests for scripts/onboard.sh. Drives the confirm-or-edit loop through the
# DELEGATE_ONBOARD_ASSUME_TTY=1 seam (a real pty can't run in CI) against a
# throwaway git repo with a known commit corpus and a mocked `curl` on a
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

# Mock the provider discovery endpoint so init.sh's environment probe succeeds
# deterministically: init.sh asks pick-model.sh what is installed, and that is
# an HTTP probe against every provider in the list.
mock="$tmp/bin"; mkdir -p "$mock"
cat > "$mock/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    */models) printf '%s' '{"object":"list","data":[{"id":"qwen3.6:35b-a3b-q8_0"}]}'; exit 0 ;;
  esac
done
exit 7
EOF
chmod +x "$mock/curl"

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

# --- T9: no provider reachable -> env section skipped, flavor still offered --
# The host variables point at closed ports rather than relying on nothing being
# installed: discovery is an HTTP probe now, so a developer machine with a live
# daemon would otherwise answer it and resolve a real model.
out=$( cd "$corpus" && env PATH="$SAFE_PATH" \
  MLX_HOST=http://localhost:1 DOCKER_MODEL_HOST=http://localhost:2 \
  OLLAMA_HOST=http://localhost:3 \
  DELEGATE_LOCAL_PROFILE="$tmp/t9p.sh" DELEGATE_LOCAL_CONFIG="$tmp/t9c.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T9: no provider reachable exits 0"
assert_contains "environment probe skipped" "$out" "T9: explains the skipped probe"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$out" "T9: flavor candidate still printed"
assert_absent "routing override candidate" "$out" "T9: no config fragment without a provider"

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

# --- M0: the data directory may not exist yet (#360) ------------------------
# The old default lived inside the installed skill directory, which always
# existed. The data directory does not, so writing has to create it. Nothing
# exercised a missing parent before.
deep="$tmp/fresh/.local/share/delegate-local"
out=$(run_onboard '\n\ny' "$deep/profile.sh" "$deep/config.sh")
if [[ -f "$deep/profile.sh" ]]; then
  echo "  PASS  M0: writes into a data directory that did not exist"; pass=$((pass+1))
else
  echo "  FAIL  M0: did not create the missing data directory"; fail=$((fail+1))
fi

# --- --migrate-data (#360) --------------------------------------------------
# User data used to default inside the installer-owned skill directory, where
# `skills update` could delete it. These pin the move across.
migrate() { # home
  env -i PATH="$SAFE_PATH" HOME="$1" bash "$SCRIPT" --migrate-data 2>&1
}
mk_legacy() { # home
  mkdir -p "$1/.claude/skills/delegate-local"
  printf '{"a":1}\n{"a":2}\n' > "$1/.claude/skills/delegate-local/metrics.jsonl"
  echo "FLAVOR=1" > "$1/.claude/skills/delegate-local/profile.sh"
  echo "3321" > "$1/.claude/skills/delegate-local/metrics.loki-sync"
}

# M1. No legacy directory at all: nothing to do, and that is not an error.
h="$tmp/m1"; mkdir -p "$h"
out=$(migrate "$h"); ec=$?
assert_eq 0 "$ec" "M1: no legacy dir exits 0"
assert_contains "nothing to migrate" "$out" "M1: says nothing to migrate"

# M2. The repoint-first trap. A legacy directory holding none of the data files
# means, on a machine that has run delegate.sh, that the skill symlink already
# moved and the history is elsewhere. Failing loudly is the point: the silent
# version reports success having copied nothing.
h="$tmp/m2"; mkdir -p "$h/.claude/skills/delegate-local"
out=$(migrate "$h"); ec=$?
assert_eq 1 "$ec" "M2: legacy dir with no data exits non-zero"
assert_contains "repointed already" "$out" "M2: names the likely cause"

# M3. The real move: copies, and carries metrics.loki-sync so the Loki
# watermark is not reset.
h="$tmp/m3"; mk_legacy "$h"
out=$(migrate "$h"); ec=$?
assert_eq 0 "$ec" "M3: migration exits 0"
for n in metrics.jsonl profile.sh metrics.loki-sync; do
  if [[ -f "$h/.local/share/delegate-local/$n" ]]; then
    echo "  PASS  M3: $n copied"; pass=$((pass+1))
  else echo "  FAIL  M3: $n not copied"; fail=$((fail+1)); fi
done
assert_eq "2" "$(grep -c '' "$h/.local/share/delegate-local/metrics.jsonl")" "M3: rows preserved"

# M4. Copy, never move — the original must survive so the operation cannot
# destroy anything.
assert_eq "2" "$(grep -c '' "$h/.claude/skills/delegate-local/metrics.jsonl")" "M4: legacy original untouched"

# M5. Idempotent: a second run finds identical targets and reports so.
out=$(migrate "$h"); ec=$?
assert_eq 0 "$ec" "M5: second run exits 0"
assert_contains "already migrated" "$out" "M5: reports already migrated"

# M6. A target that exists and DIFFERS is never overwritten.
echo '{"different":true}' > "$h/.local/share/delegate-local/metrics.jsonl"
out=$(migrate "$h"); ec=$?
assert_eq 1 "$ec" "M6: differing target exits non-zero"
assert_contains "refusing to overwrite" "$out" "M6: refuses to overwrite"
assert_eq "2" "$(grep -c '' "$h/.claude/skills/delegate-local/metrics.jsonl")" "M6: legacy still untouched"

# M7. DELEGATE_LOCAL_DATA_DIR redirects the destination.
h="$tmp/m7"; mk_legacy "$h"
out=$(env -i PATH="$SAFE_PATH" HOME="$h" DELEGATE_LOCAL_DATA_DIR="$h/custom" \
      bash "$SCRIPT" --migrate-data 2>&1)
if [[ -f "$h/custom/metrics.jsonl" ]]; then
  echo "  PASS  M7: honours DELEGATE_LOCAL_DATA_DIR"; pass=$((pass+1))
else echo "  FAIL  M7: ignored DELEGATE_LOCAL_DATA_DIR"; fail=$((fail+1)); fi

# --- T12: commit body SHAPE is derived from the word cap ---------------------
# A recipe that states both a structural shape and a word cap can be handed two
# instructions that contradict each other. "1-2 short flowing-prose paragraphs"
# fits the shipped 120-word cap and is unwritable under a profile that tightens
# it to 50. Measured 2026-08-26 against a real merged diff at temperature 0: the
# previous wording produced a 92-word body on four of four reps, the derived
# shape 45 on four of four. 92 is the number the production rejection reason
# named. The derivation runs AFTER the profile is sourced so an override feeds
# into it.
t12=$(mktemp -d)
out=$(env DELEGATE_LOCAL_PROFILE="$t12/absent.sh" bash "$REPO/scripts/load-flavor.sh")
assert_contains "flavor_commit_body_shape=1-2 short flowing-prose paragraphs" "$out" \
  "T12: the shipped 120-word cap derives the two-paragraph shape"

mkprof() { printf '%s\n' "$1" > "$t12/p.sh"; chmod 600 "$t12/p.sh"; }
lf() { env DELEGATE_LOCAL_PROFILE="$t12/p.sh" bash "$REPO/scripts/load-flavor.sh" 2>/dev/null; }

mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=50'
out=$(lf)
assert_contains "flavor_commit_body_shape=one short flowing-prose paragraph" "$out" \
  "T12: a tightened cap derives the one-paragraph shape"
assert_contains "flavor_commit_body_max_words=50" "$out" \
  "T12: the tightened cap itself still resolves"

# The threshold is inclusive at 60 and releases at 61.
mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=60'
assert_contains "flavor_commit_body_shape=one short flowing-prose paragraph" "$(lf)" \
  "T12: 60 is inside the one-paragraph band"
mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=61'
assert_contains "flavor_commit_body_shape=1-2 short flowing-prose paragraphs" "$(lf)" \
  "T12: 61 is outside it"

# An explicit profile value wins; the derivation only fills the gap.
mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=50
FLAVOR_COMMIT_BODY_SHAPE="three terse bullet-free sentences"'
assert_contains "flavor_commit_body_shape=three terse bullet-free sentences" "$(lf)" \
  "T12: an explicit shape in the profile beats the derivation"

# A zero-padded value is still base 10. Without `10#` bash reads `08` as octal,
# aborts the arithmetic with "value too great for base", and leaks that to the
# caller's stderr mid-recipe while silently taking the wrong branch.
mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=08'
out=$(env DELEGATE_LOCAL_PROFILE="$t12/p.sh" bash "$REPO/scripts/load-flavor.sh" 2>&1)
assert_contains "flavor_commit_body_shape=one short flowing-prose paragraph" "$out" \
  "T12: a zero-padded cap takes the one-paragraph branch"
if [[ "$out" == *"value too great for base"* ]]; then
  echo "  FAIL  T12: a zero-padded cap must not leak an arithmetic error"; fail=$((fail+1))
else
  echo "  PASS  T12: a zero-padded cap leaks no arithmetic error"; pass=$((pass+1))
fi

# A non-numeric cap must not crash the resolver or leave the shape unset.
mkprof 'FLAVOR_COMMIT_BODY_MAX_WORDS=lots'
assert_contains "flavor_commit_body_shape=1-2 short flowing-prose paragraphs" "$(lf)" \
  "T12: a non-numeric cap falls back to the shipped shape"
rm -rf "$t12"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
