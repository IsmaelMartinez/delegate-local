#!/usr/bin/env bash
# Unit tests for scripts/onboard.sh, driving the confirm-or-edit loop through
# the DELEGATE_ONBOARD_ASSUME_TTY=1 seam (a real pty cannot run in CI).

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

# A provider serving a model, so T1 shows no routing override is offered even
# when one could be generated (init.sh did, until #567).
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
# The hook step merges with jq, which SAFE_PATH may not hold.
ln -s "$(command -v jq)" "$mock/jq"

# Corpus repo: subject lengths 7,7,9,10,14,17 (P90 max 14); types feat x3 +
# fix x2 (docs once, dropped by the >=2 rule). No tie, since sort(1)'s
# last-resort comparison is unstable.
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

# run_onboard <answers> <profile> [extra env assignments...]
run_onboard() {
  local answers="$1" profile="$2"; shift 2
  ( cd "$corpus" && printf '%b' "$answers" | \
    env PATH="$mock:$SAFE_PATH" DELEGATE_ONBOARD_ASSUME_TTY=1 \
        DELEGATE_ONBOARD_SETTINGS="$tmp/no-settings.json" \
        DELEGATE_LOCAL_PROFILE="$profile" "$@" \
        bash "$SCRIPT" 2>&1 )
}

# --- T1: non-interactive -> print-only, nothing written ----------------------
out=$( cd "$corpus" && env PATH="$mock:$SAFE_PATH" \
  DELEGATE_ONBOARD_SETTINGS="$tmp/no-settings.json" \
  DELEGATE_LOCAL_PROFILE="$tmp/t1p.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T1: print-only exits 0"
assert_absent "routing override" "$out" "T1: offers no routing override (init.sh is gone, #567)"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$out" "T1: prints the derived subject max"
assert_contains 'FLAVOR_COMMIT_TYPES="feat, fix"' "$out" "T1: prints the derived type list"
assert_contains "wrote nothing" "$out" "T1: says it wrote nothing"
[[ ! -f "$tmp/t1p.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T1: no profile created"

# --- T2: accept-all -> profile written, mode 600, derived values ------------
out=$(run_onboard '\n\n' "$tmp/t2p.sh"); ec=$?
assert_eq "0" "$ec" "T2: accept-all exits 0"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$(cat "$tmp/t2p.sh")" "T2: profile carries derived subject max"
assert_contains 'FLAVOR_COMMIT_TYPES="feat, fix"' "$(cat "$tmp/t2p.sh")" "T2: profile carries derived types"
# perl for the mode read — GNU stat treats -f as "filesystem status" and
# SUCCEEDS with the wrong semantics, so a BSD-first || fallback never fires.
mode=$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$tmp/t2p.sh")
assert_eq "600" "$mode" "T2: profile written mode 600"

# --- T3: typed override replaces the prefill ---------------------------------
out=$(run_onboard '60\n\n' "$tmp/t3p.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=60" "$(cat "$tmp/t3p.sh")" "T3: typed subject max written"

# --- T4: existing profile + decline overwrite -> untouched, no backup --------
echo "FLAVOR_COMMIT_SUBJECT_MAX=99" > "$tmp/t4p.sh"
out=$(run_onboard '\n\nn\n' "$tmp/t4p.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=99" "$(cat "$tmp/t4p.sh")" "T4: declined overwrite leaves profile untouched"
assert_contains "kept existing" "$out" "T4: explains the decline"
[[ -z "$(ls "$tmp"/t4p.sh.bak.* 2>/dev/null)" ]] && r=ok || r=bak
assert_eq "ok" "$r" "T4: no backup created on decline"

# --- T5: existing profile + confirm -> backup holds old, target holds new ----
echo "FLAVOR_COMMIT_SUBJECT_MAX=99" > "$tmp/t5p.sh"
out=$(run_onboard '\n\ny\n' "$tmp/t5p.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$(cat "$tmp/t5p.sh")" "T5: confirmed overwrite wrote new values"
bak=$(ls "$tmp"/t5p.sh.bak.* 2>/dev/null | head -1)
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=99" "$(cat "$bak")" "T5: backup preserves the old profile"

# --- T6: quit at the first prompt -> nothing written -------------------------
out=$(run_onboard 'q\n' "$tmp/t6p.sh"); ec=$?
assert_eq "0" "$ec" "T6: quit exits 0"
assert_contains "nothing written" "$out" "T6: quit says nothing written"
[[ ! -f "$tmp/t6p.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T6: quit created no files"

# --- T7: skip both keys -> profile not written -----------------------------
out=$(run_onboard 's\ns\n' "$tmp/t7p.sh")
assert_contains "profile not written" "$out" "T7: skip-both explains no profile"
[[ ! -f "$tmp/t7p.sh" ]] && r=ok || r=written
assert_eq "ok" "$r" "T7: skip-both wrote no profile"

# --- T8: non-git cwd -> shipped defaults as prefill, still exits 0 -----------
empty="$tmp/empty"; mkdir -p "$empty"
out=$( cd "$empty" && env PATH="$mock:$SAFE_PATH" \
  DELEGATE_ONBOARD_SETTINGS="$tmp/no-settings.json" \
  DELEGATE_LOCAL_PROFILE="$tmp/t8p.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T8: non-git cwd exits 0"
assert_contains "fall back to shipped defaults" "$out" "T8: explains the fallback"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=72" "$out" "T8: shipped default becomes the prefill"

# --- T9: no provider reachable -> onboarding needs none ----------------------
# Host variables point at closed ports, or a live daemon would answer.
out=$( cd "$corpus" && env PATH="$SAFE_PATH" \
  MLX_HOST=http://localhost:1 DOCKER_MODEL_HOST=http://localhost:2 \
  OLLAMA_HOST=http://localhost:3 \
  DELEGATE_ONBOARD_SETTINGS="$tmp/no-settings.json" \
  DELEGATE_LOCAL_PROFILE="$tmp/t9p.sh" \
  bash "$SCRIPT" </dev/null 2>&1 ); ec=$?
assert_eq "0" "$ec" "T9: no provider reachable exits 0"
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$out" "T9: flavor candidate still printed"

# --- T10: invalid edit re-prompts, then a valid retry is accepted ------------
out=$(run_onboard 'abc\n55\n\n' "$tmp/t10p.sh")
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
echo "FLAVOR_COMMIT_SUBJECT_MAX=99" > "$tmp/t13p.sh"
out=$(run_onboard '\n\ny' "$tmp/t13p.sh")
assert_contains "FLAVOR_COMMIT_SUBJECT_MAX=14" "$(cat "$tmp/t13p.sh")" "T13: overwrite confirmed by an unterminated trailing y"

# --- H: the hook step (#528) — boundary/confirm/Stop entries in settings.json.
# Every run points DELEGATE_ONBOARD_SETTINGS at a temp file; the real
# ~/.claude/settings.json is never read or written here. Answers: skip both
# flavor keys, then the hook answer.
hooks_cmd='bash ~/.claude/skills/delegate-local/scripts'
pre_entry="{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$hooks_cmd/delegate-boundary-hook.sh\",\"timeout\":5}]}"
post_entry="{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$hooks_cmd/delegate-boundary-confirm-hook.sh\",\"timeout\":5}]}"
stop_entry="{\"hooks\":[{\"type\":\"command\",\"command\":\"$hooks_cmd/delegate-verdict-stop-hook.sh\",\"timeout\":10}]}"
# Unrelated hooks, matchers and keys every merge must leave exactly as they were.
unrelated='{
  "env": {"FOO": "bar"},
  "permissions": {"allow": ["Bash(git status)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/smart-reads-inject.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "bash .claude/hooks/post-edit-validate.sh", "timeout": 30}]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/herdr.sh session"}]}
    ]
  }
}'
run_hooks() { # <answers> <settings> -> combined output
  run_onboard "$1" "$tmp/hp.sh" DELEGATE_ONBOARD_SETTINGS="$2"
}
jqs() { jq -S . "$1"; }

# H1 (a): boundary hook and Stop hook present, no confirm hook -> reported
# incomplete; confirming adds only the PostToolUse confirm entry.
s="$tmp/h1.json"
printf '%s\n' "$unrelated" | jq --argjson pre "$pre_entry" --argjson stop "$stop_entry" \
  '.hooks.PreToolUse += [$pre] | .hooks.Stop = [$stop]' > "$s"
cp "$s" "$tmp/h1.orig"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_contains "boundary hook (PreToolUse): present" "$out" "H1: reports the boundary hook present"
assert_contains "confirm hook (PostToolUse): absent" "$out" "H1: reports the confirm hook absent"
assert_contains "verdict hook (Stop): present" "$out" "H1: reports the Stop hook present"
assert_contains "incomplete" "$out" "H1: a boundary hook without its confirm hook is incomplete"
assert_eq "$(jq -c --argjson e "$post_entry" '.hooks.PostToolUse + [$e]' "$tmp/h1.orig")" \
  "$(jq -c '.hooks.PostToolUse' "$s")" "H1: the confirm entry is appended after the existing PostToolUse matcher"
assert_eq "$(jqs "$tmp/h1.orig")" "$(jq -S 'del(.hooks.PostToolUse[-1])' "$s")" \
  "H1: everything but the confirm entry is unchanged"
bak=$(ls "$s".bak.* 2>/dev/null | head -1)
if [[ -n "$bak" ]] && cmp -s "$bak" "$tmp/h1.orig"; then
  echo "  PASS  H1: a byte-identical backup is kept"; pass=$((pass+1))
else echo "  FAIL  H1: no byte-identical backup of the settings file"; fail=$((fail+1)); fi

# H2 (b)+(d): none of the three present -> all reported absent; confirming
# installs the pair plus the Stop hook, unrelated entries preserved.
s="$tmp/h2.json"
printf '%s\n' "$unrelated" | jq . > "$s"
cp "$s" "$tmp/h2.orig"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_contains "boundary hook (PreToolUse): absent" "$out" "H2: reports the boundary hook absent"
assert_contains "confirm hook (PostToolUse): absent" "$out" "H2: reports the confirm hook absent"
assert_contains "verdict hook (Stop): absent" "$out" "H2: reports the Stop hook absent"
assert_eq "$(jq -c --argjson e "$pre_entry" '.hooks.PreToolUse + [$e]' "$tmp/h2.orig")" \
  "$(jq -c '.hooks.PreToolUse' "$s")" "H2: boundary entry appended to PreToolUse"
assert_eq "$(jq -c --argjson e "$post_entry" '.hooks.PostToolUse + [$e]' "$tmp/h2.orig")" \
  "$(jq -c '.hooks.PostToolUse' "$s")" "H2: confirm entry appended to PostToolUse"
assert_eq "[$stop_entry]" "$(jq -c '.hooks.Stop' "$s")" "H2: Stop array created with the verdict entry"
assert_eq "$(jqs "$tmp/h2.orig")" \
  "$(jq -S 'del(.hooks.Stop) | del(.hooks.PreToolUse[-1]) | del(.hooks.PostToolUse[-1])' "$s")" \
  "H2: unrelated hooks, matchers and keys preserved"
# Outside the added entries the bytes are the input's own (it is jq-formatted).
assert_eq "$(cat "$tmp/h2.orig")" \
  "$(jq 'del(.hooks.Stop) | del(.hooks.PreToolUse[-1]) | del(.hooks.PostToolUse[-1])' "$s")" \
  "H2: bytes outside the added entries unchanged"

# H3: a complete install reports all present and asks nothing.
cp "$s" "$tmp/h3.orig"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_contains "all three hooks are installed" "$out" "H3: a complete install says so"
assert_absent "install the missing hook" "$out" "H3: nothing to install, no prompt"
cmp -s "$s" "$tmp/h3.orig" && r=ok || r=changed
assert_eq "ok" "$r" "H3: a complete install is not rewritten"

# H4 (c): a decline writes nothing and keeps no backup.
s="$tmp/h4.json"
printf '%s\n' "$unrelated" > "$s"
cp "$s" "$tmp/h4.orig"
out=$(run_hooks 's\ns\nn\n' "$s")
assert_contains "hooks not installed" "$out" "H4: explains the decline"
cmp -s "$s" "$tmp/h4.orig" && r=ok || r=changed
assert_eq "ok" "$r" "H4: declined settings file byte-identical"
[[ -z "$(ls "$s".bak.* 2>/dev/null)" ]] && r=ok || r=bak
assert_eq "ok" "$r" "H4: no backup created on decline"

# H5 (e): a malformed settings file is reported and never overwritten.
s="$tmp/h5.json"
printf '{"hooks": [\n' > "$s"
cp "$s" "$tmp/h5.orig"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_contains "not valid JSON" "$out" "H5: malformed settings reported"
cmp -s "$s" "$tmp/h5.orig" && r=ok || r=changed
assert_eq "ok" "$r" "H5: malformed settings never overwritten"
[[ -z "$(ls "$s".bak.* 2>/dev/null)" ]] && r=ok || r=bak
assert_eq "ok" "$r" "H5: no backup of a malformed file"

# H6: no settings file yet -> confirming creates one holding all three.
s="$tmp/h6dir/settings.json"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_eq "[$pre_entry]|[$post_entry]|[$stop_entry]" \
  "$(jq -c '.hooks.PreToolUse' "$s" 2>/dev/null)|$(jq -c '.hooks.PostToolUse' "$s" 2>/dev/null)|$(jq -c '.hooks.Stop' "$s" 2>/dev/null)" \
  "H6: a missing settings file is created with the three entries"

# H7: without a terminal the hook status is printed and nothing is written.
s="$tmp/h7.json"
cp "$tmp/h1.orig" "$s"
out=$( cd "$corpus" && env PATH="$mock:$SAFE_PATH" DELEGATE_ONBOARD_SETTINGS="$s" \
  DELEGATE_LOCAL_PROFILE="$tmp/h7p.sh" \
  bash "$SCRIPT" </dev/null 2>&1 )
assert_contains "confirm hook (PostToolUse): absent" "$out" "H7: print-only reports the missing confirm hook"
assert_contains "incomplete" "$out" "H7: print-only flags the incomplete install"
assert_contains "delegate-boundary-confirm-hook.sh" "$out" "H7: print-only shows the entry to add"
cmp -s "$s" "$tmp/h1.orig" && r=ok || r=changed
assert_eq "ok" "$r" "H7: print-only leaves the settings file untouched"

# H8: presence means registered for Bash. A boundary hook under a Read matcher
# never sees a Bash call, so it is absent and the Bash entry is appended.
s="$tmp/h8.json"
read_pre=$(printf '%s' "$pre_entry" | jq -c '.matcher = "Read"')
jq -n --argjson e "$read_pre" --argjson post "$post_entry" --argjson stop "$stop_entry" \
  '{hooks: {PreToolUse: [$e], PostToolUse: [$post], Stop: [$stop]}}' > "$s"
out=$(run_hooks 's\ns\ny\n' "$s")
assert_contains "boundary hook (PreToolUse): absent" "$out" "H8: a boundary hook under a Read matcher is absent"
assert_eq "[$read_pre,$pre_entry]" "$(jq -c '.hooks.PreToolUse' "$s")" \
  "H8: the Bash boundary entry is appended beside the Read one"

# H9: matchers Claude Code applies to Bash count as present: a |-list naming
# Bash, "*", and an empty or absent matcher.
for m in '"Edit|Bash"' '"*"' '""' 'null'; do
  s="$tmp/h9.json"
  jq -n --argjson m "$m" --argjson pre "$pre_entry" --argjson post "$post_entry" --argjson stop "$stop_entry" \
    '{hooks: {PreToolUse: [$pre | .matcher = $m | if $m == null then del(.matcher) else . end],
              PostToolUse: [$post], Stop: [$stop]}}' > "$s"
  out=$(run_hooks 's\ns\ny\n' "$s")
  assert_contains "boundary hook (PreToolUse): present" "$out" "H9: matcher $m applies to Bash"
done

# H10: a new settings file is created 0600 whatever the umask; an existing
# file keeps its own mode.
s="$tmp/h10dir/settings.json"
out=$( umask 022; run_hooks 's\ns\ny\n' "$s" )
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$s" 2>/dev/null)" \
  "H10: a new settings file is created mode 600"
s="$tmp/h10b.json"
printf '{}\n' > "$s"; chmod 644 "$s"
out=$( umask 077; run_hooks 's\ns\ny\n' "$s" )
assert_eq "644" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$s")" \
  "H10: an existing settings file keeps its mode"

# --- M0: the data directory may not exist yet, so writing creates it (#360) --
deep="$tmp/fresh/.local/share/delegate-local"
out=$(run_onboard '\n\n' "$deep/profile.sh")
if [[ -f "$deep/profile.sh" ]]; then
  echo "  PASS  M0: writes into a data directory that did not exist"; pass=$((pass+1))
else
  echo "  FAIL  M0: did not create the missing data directory"; fail=$((fail+1))
fi

# --- --migrate-data (#360): user data moves out of the installer-owned skill
# directory, where `skills update` could delete it ---------------------------
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

# M2. A legacy directory holding none of the data files means the history is
# elsewhere; fail loudly rather than report success having copied nothing.
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

# --- T12: the commit body shape is derived from the word cap, after the
# profile is sourced, so a tightened cap cannot contradict the shape ---------
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

# A zero-padded value is base 10: without `10#` bash reads `08` as octal.
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
