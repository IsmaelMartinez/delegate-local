#!/usr/bin/env bash
# Unit tests for scripts/self-improve.sh — the gate and evidence bundle the
# recurring calibration session runs on.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/self-improve.sh"

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
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpectedly found '$needle')"; fail=$((fail+1)); fi
}

# Timestamps are generated relative to now so the rolling-window sections
# (--days) include the seeded rows regardless of when the suite runs.
iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-$ARGV[0]))' "$1"; }

echo "== self-improve.sh =="

# 1. A missing metrics file is a usage error, not a silent no-op.
EC=0
out=$(bash "$SCRIPT" --file /nonexistent/metrics.jsonl 2>&1) || EC=$?
assert_eq 2 "$EC" "missing metrics file exits 2"
assert_contains "metrics file not found" "$out" "missing metrics file names the path"

# 2. A metrics file with no delegate rows is the quiet path, not an error.
tmp=$(mktemp -d)
echo '{"ts":"2026-08-01T00:00:00Z","source":"feedback","ref_ts":"x","kept":false}' > "$tmp/m.jsonl"
EC=0
out=$(bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 10 "$EC" "no delegate rows exits 10 (quiet)"
rm -rf "$tmp"

# 3. Bad numeric arguments fail loudly rather than being coerced.
tmp=$(mktemp -d); echo '{}' > "$tmp/m.jsonl"
EC=0; out=$(bash "$SCRIPT" --file "$tmp/m.jsonl" --days abc 2>&1) || EC=$?
assert_eq 2 "$EC" "--days must be numeric"
EC=0; out=$(bash "$SCRIPT" --file "$tmp/m.jsonl" --min-delegations x 2>&1) || EC=$?
assert_eq 2 "$EC" "--min-delegations must be numeric"
EC=0; out=$(bash "$SCRIPT" --file "$tmp/m.jsonl" --bogus 2>&1) || EC=$?
assert_eq 2 "$EC" "unknown argument exits 2"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# A seeded corpus with the three shapes the bundle has to render: a rejection
# with a captured draft/final pair, a rejection with NEITHER captured (the
# common case today, and the one that exposed the field-shift bug), and a kept
# delegation that must not appear in the rejection list at all.
# ---------------------------------------------------------------------------
seed() {
  local dir="$1" t1 t2 t3
  t1=$(iso_ago 3600); t2=$(iso_ago 1800); t3=$(iso_ago 600)
  mkdir -p "$dir/drafts"
  cat > "$dir/m.jsonl" <<EOF
{"ts":"$t1","source":"delegate","tier":"prose","model":"q","recipe":"maintainer-reply","project":"pr-agent","duration_ms":2000,"exit_status":0,"estimated_tokens_avoided":100,"draft_file":"D1.draft.txt"}
{"ts":"$(iso_ago 3590)","source":"feedback","ref_ts":"$t1","kept":false,"reason":"dropped every anchor","verdict_source":"agent","final_file":"D1.final.txt"}
{"ts":"$t2","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"delegate-local","duration_ms":2000,"exit_status":0,"estimated_tokens_avoided":100,"checks_run":3,"checks_failed":1,"checks_autofixed":0,"checks_failed_names":["no_padding_tail"]}
{"ts":"$(iso_ago 1790)","source":"feedback","ref_ts":"$t2","kept":false,"reason":"two paragraphs against a one-sentence house style","verdict_source":"agent"}
{"ts":"$t3","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"delegate-local","duration_ms":2000,"exit_status":0,"estimated_tokens_avoided":100}
{"ts":"$(iso_ago 590)","source":"feedback","ref_ts":"$t3","kept":true,"verdict_source":"agent"}
EOF
  cat > "$dir/drafts/D1.draft.txt" <<'EOF'
Thanks for the report.
1. Does it reproduce on 2.9?
EOF
  cat > "$dir/drafts/D1.final.txt" <<'EOF'
The blank window comes from the sandbox flag in `src/main.js`, not your distro. PR #2632 and all 531 tests confirm it.

Could you paste the launch flags?
EOF
}

tmp=$(mktemp -d); seed "$tmp"
STATE="$tmp/state"

# 4. First run: no watermark, so the whole corpus is new.
EC=0
out=$(DELEGATE_SELF_IMPROVE_STATE="$STATE" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "first run with new delegations exits 0"
assert_contains "New delegations since watermark: 3" "$out" "first run counts every delegate row"
assert_contains "agent (usage):    n=3  used=1 scaffold=0 rewrote=2" "$out" \
  "verdict tally splits used from rewritten inside the agent tier"

# 5. The per-recipe section ranks worst keep-rate first.
recipes=$(printf '%s\n' "$out" | sed -n '/per-recipe outcomes/,/^$/p' | grep -E '^  [a-z]' | head -2)
assert_contains "maintainer-reply" "$(printf '%s' "$recipes" | head -1)" \
  "per-recipe section puts the 0% recipe first"
assert_contains "usable=50%" "$out" "per-recipe section computes a usable rate"

# 6. Deterministic check failures are clustered by recipe and name.
assert_contains "commit-message: no_padding_tail × 1" "$out" "check failures cluster by recipe and check name"

# 7. The rejection with an empty draft_file/final_file still renders its
# verdict and reason. This is the regression guard for the field-shift bug:
# a tab-separated record read with IFS=$'\t' collapses the two empty fields
# and silently shifts verdict and reason out of the record.
assert_contains "[rewrote]" "$out" "rejection with no captured files still shows its verdict"
assert_contains "two paragraphs against a one-sentence house style" "$out" \
  "rejection with no captured files still shows its reason"
assert_contains "(not captured)" "$out" "uncaptured draft is reported as such"

# 8. The kept delegation is not in the rejection list.
rejections=$(printf '%s\n' "$out" | sed -n '/rejected drafts/,/capture coverage/p')
assert_not_contains "[kept]" "$rejections" "kept delegations are excluded from the rejection list"

# 9. The draft/final pair produces the objective diff. DROPPED is the signal
# the free-text reason cannot give: which specific anchors the human had to
# put back.
assert_contains "DROPPED" "$out" "captured pair yields a DROPPED list"
assert_contains "src/main.js" "$out" "DROPPED names the anchor the draft omitted"
assert_contains "#2632" "$out" "DROPPED names the issue reference the draft omitted"
assert_contains "INVENTED" "$out" "captured pair yields an INVENTED list"
assert_contains "2.9" "$out" "INVENTED names the value the draft made up"
assert_contains "SHAPE: draft used" "$out" "captured pair reports the list-vs-prose shape delta"

# 10. Capture coverage is reported, so the loop can see its own blind spot.
assert_contains "rejections=2  with draft=1  with final=1" "$out" "capture coverage counted"

# 11. The watermark advanced, so a second run has nothing to do.
assert_eq "$(jq -r 'select(.source=="delegate") | .ts' "$tmp/m.jsonl" | tail -1)" \
  "$(cat "$STATE")" "watermark records the newest delegate ts"
EC=0
out2=$(DELEGATE_SELF_IMPROVE_STATE="$STATE" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 10 "$EC" "second run with no new delegations exits 10"
assert_eq "" "$(DELEGATE_SELF_IMPROVE_STATE="$STATE" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>/dev/null)" \
  "quiet path writes nothing to stdout"
rm -rf "$tmp"

# 12. --peek reports without consuming the window.
tmp=$(mktemp -d); seed "$tmp"
STATE="$tmp/state"
DELEGATE_SELF_IMPROVE_STATE="$STATE" bash "$SCRIPT" --file "$tmp/m.jsonl" --peek >/dev/null 2>&1
if [[ -f "$STATE" ]]; then
  echo "  FAIL  --peek must not write the watermark"; fail=$((fail+1))
else
  echo "  PASS  --peek does not write the watermark"; pass=$((pass+1))
fi
EC=0
DELEGATE_SELF_IMPROVE_STATE="$STATE" bash "$SCRIPT" --file "$tmp/m.jsonl" --peek >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "--peek still reports on a second call"
rm -rf "$tmp"

# 13. --min-delegations gates the session on volume, so a single stray
# delegation does not wake a full calibration pass.
tmp=$(mktemp -d); seed "$tmp"
EC=0
out=$(DELEGATE_SELF_IMPROVE_STATE="$tmp/state" bash "$SCRIPT" --file "$tmp/m.jsonl" --min-delegations 5 2>&1) || EC=$?
assert_eq 10 "$EC" "--min-delegations above the new count exits 10"
assert_contains "nothing to do" "$out" "gated run says why on stderr"
rm -rf "$tmp"

# 14. A reason containing a tab or newline cannot break the record framing.
tmp=$(mktemp -d); seed "$tmp"
t=$(iso_ago 300)
{
  printf '{"ts":"%s","source":"delegate","recipe":"x","project":"p","exit_status":0}\n' "$t"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"reason":"tab\\there and\\nnewline there"}\n' "$(iso_ago 290)" "$t"
} >> "$tmp/m.jsonl"
out=$(DELEGATE_SELF_IMPROVE_STATE="$tmp/state" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1)
assert_contains "tab here and newline there" "$out" "control characters in a reason are flattened, not framed"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# ADR 0015 verdict tiers. A human recording their own taste judgment is the
# quality signal; `--source agent` is the agent saying whether it used its own
# draft, which is usage. metrics-summary.sh has always kept them apart and this
# script used to add them together under the word "kept". With a corpus at 100%
# agent verdicts the blend is invisible, so these assertions seed BOTH tiers.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d); mkdir -p "$tmp/drafts"
t1=$(iso_ago 3600); t2=$(iso_ago 1800); t3=$(iso_ago 900)
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$t1","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"p","duration_ms":1,"exit_status":0,"estimated_tokens_avoided":1}
{"ts":"$(iso_ago 3590)","source":"feedback","ref_ts":"$t1","kept":true}
{"ts":"$t2","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"p","duration_ms":1,"exit_status":0,"estimated_tokens_avoided":1}
{"ts":"$(iso_ago 1790)","source":"feedback","ref_ts":"$t2","kept":false,"scaffold":true,"reason":"trimmed the body","verdict_source":"agent"}
{"ts":"$t3","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"p","duration_ms":1,"exit_status":0,"estimated_tokens_avoided":1}
{"ts":"$(iso_ago 890)","source":"feedback","ref_ts":"$t3","kept":false,"reason":"discarded","verdict_source":"agent"}
EOF
out=$(DELEGATE_SELF_IMPROVE_STATE="$tmp/state" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1)
assert_contains "human (quality):  n=1" "$out" \
  "verdict tiers: the human tier is counted on its own"
assert_contains "agent (usage):    n=2" "$out" \
  "verdict tiers: the agent tier is counted on its own"
# The blend this replaces would have printed "kept=1 scaffold=1 rewrote=1" as a
# single line with no tier named at all.
if [[ "$out" == *"3 total — kept="* ]]; then
  echo "  FAIL  verdict tiers: the two tiers must not be summed under one 'kept'"; fail=$((fail+1))
else
  echo "  PASS  verdict tiers: the two tiers are not summed under one 'kept'"; pass=$((pass+1))
fi
# Ranking is on kept+scaffold. Two of the three commit-message drafts were used
# (one kept, one edited and shipped), so the row must read 66%, not the 33% a
# kept-only rate would give.
assert_contains "usable=66%" "$out" \
  "verdict tiers: the per-recipe rate counts scaffolded drafts as used"
assert_contains "h=1" "$out" \
  "verdict tiers: the per-recipe row says how much of it is human judgment"
rm -rf "$tmp"

# An all-agent window must say plainly that there is no keep rate to quote,
# rather than printing a 0% that reads as a quality collapse.
tmp=$(mktemp -d); mkdir -p "$tmp/drafts"
t1=$(iso_ago 3600)
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$t1","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"p","duration_ms":1,"exit_status":0,"estimated_tokens_avoided":1}
{"ts":"$(iso_ago 3590)","source":"feedback","ref_ts":"$t1","kept":false,"reason":"no","verdict_source":"agent"}
EOF
out=$(DELEGATE_SELF_IMPROVE_STATE="$tmp/state" bash "$SCRIPT" --file "$tmp/m.jsonl" 2>&1)
assert_contains "no human taste judgment in this window" "$out" \
  "verdict tiers: an all-agent window says there is no keep rate to quote"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
