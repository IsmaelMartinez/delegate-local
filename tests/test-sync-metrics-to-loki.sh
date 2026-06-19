#!/usr/bin/env bash
# Unit tests for scripts/sync-metrics-to-loki.sh. Mocks curl on a restricted
# PATH so the Loki push body is captured to a file instead of escaping the
# host, and asserts the stream grouping, ns-timestamp encoding, feedback
# recipe/tier enrichment, watermark idempotency, and dry-run behaviour.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/sync-metrics-to-loki.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0
assert_eq() { if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1)); else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi; }
assert_contains() { case "$2" in *"$1"*) echo "  PASS  $3"; pass=$((pass+1));; *) echo "  FAIL  $3 (missing '$1')"; fail=$((fail+1));; esac; }

# Mock curl: capture the --data-binary push body to $BODY, respond 204 to the
# push and flush; everything else 204.
make_mock_curl() {
  local dir="$1" body="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--data-binary" ]]; then printf '%s' "\$a" > "$body"; fi
  prev="\$a"
done
# emulate -w '%{http_code}' -o FILE: write nothing to the -o file, echo code
echo -n "204"
exit 0
EOF
  chmod +x "$dir/curl"
}

tmp=$(mktemp -d)
body="$tmp/body.json"
make_mock_curl "$tmp" "$body"
met="$tmp/m.jsonl"
state="$tmp/state"

# Fixture: a delegate row (with recipe+tier), a feedback row whose ref_ts points
# at it, two delegate rows sharing the SAME second (duplicate-ts disambiguation),
# and a bare-tier delegate row (no recipe).
cat > "$met" <<'EOF'
{"ts":"2026-05-10T10:00:00Z","source":"delegate","tier":"prose","recipe":"commit-message","estimated_tokens_avoided":42,"exit_status":0,"project":"repo-x"}
{"ts":"2026-05-10T10:00:05Z","source":"delegate","tier":"code","estimated_tokens_avoided":7,"exit_status":0,"project":"repo-x"}
{"ts":"2026-05-10T10:00:05Z","source":"delegate","tier":"code","estimated_tokens_avoided":9,"exit_status":2,"project":"repo-y"}
{"ts":"2026-05-10T10:05:00Z","source":"feedback","ref_ts":"2026-05-10T10:00:00Z","kept":true,"project":"repo-x"}
EOF

# --- T1: dry-run makes no push, reports counts -----------------------------
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --dry-run --metrics-file "$met" --state-file "$state" --loki-url http://x 2>&1)
assert_contains "DRY RUN" "$out" "T1: dry-run announced"
assert_contains '"source":"delegate","count":3' "$out" "T1: 3 delegate rows grouped"
assert_contains '"source":"feedback","count":1' "$out" "T1: 1 feedback row grouped"
[[ -f "$body" ]] && { echo "  FAIL  T1: dry-run must not push a body"; fail=$((fail+1)); } || { echo "  PASS  T1: dry-run pushed nothing"; pass=$((pass+1)); }

# --- T2: real push captures a well-formed payload --------------------------
rm -f "$state" "$body"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --metrics-file "$met" --state-file "$state" --loki-url http://x >/dev/null 2>&1 || EC=$?
assert_eq "0" "$EC" "T2: push run exits 0"
if [[ -f "$body" ]] && jq empty "$body" >/dev/null 2>&1; then
  echo "  PASS  T2: push body is valid JSON"; pass=$((pass+1))
else
  echo "  FAIL  T2: push body missing or invalid"; fail=$((fail+1))
fi
# Stream labels: service + source, two source streams.
src_streams=$(jq -r '[.streams[].stream.source] | sort | join(",")' "$body")
assert_eq "delegate,feedback" "$src_streams" "T2: one stream per source"
svc=$(jq -r '[.streams[].stream.service] | unique | join(",")' "$body")
assert_eq "delegate-local" "$svc" "T2: service label is delegate-local"

# --- T3: ns timestamps are 19-digit and unique (duplicate-second rows) ------
ns_lens=$(jq -r '[.streams[].values[][0] | length] | unique | join(",")' "$body")
assert_eq "19" "$ns_lens" "T3: every ns timestamp is 19 digits"
ns_total=$(jq -r '[.streams[].values[][0]] | length' "$body")
ns_unique=$(jq -r '[.streams[].values[][0]] | unique | length' "$body")
assert_eq "$ns_total" "$ns_unique" "T3: all ns timestamps unique (same-second rows disambiguated)"

# --- T4: feedback row enriched with parent recipe + tier --------------------
fb_line=$(jq -r '.streams[] | select(.stream.source=="feedback") | .values[0][1]' "$body")
fb_recipe=$(printf '%s' "$fb_line" | jq -r '.recipe // ""')
fb_tier=$(printf '%s' "$fb_line" | jq -r '.tier // ""')
assert_eq "commit-message" "$fb_recipe" "T4: feedback enriched with parent recipe"
assert_eq "prose" "$fb_tier" "T4: feedback enriched with parent tier"

# --- T5: watermark idempotency ---------------------------------------------
assert_eq "4" "$(cat "$state")" "T5: watermark set to row count"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --metrics-file "$met" --state-file "$state" --loki-url http://x 2>&1)
assert_contains "nothing new to push" "$out" "T5: second run is a no-op"

# --- T6: a malformed/partial row aborts WITHOUT advancing the watermark -----
# (a torn final line from the sync racing an in-progress delegate.sh append
# must be retried, not silently skipped past).
met2="$tmp/m2.jsonl"; state2="$tmp/state2"; body2="$tmp/body2.json"
make_mock_curl "$tmp" "$body2"
printf '%s\n' '{"ts":"2026-05-10T10:00:00Z","source":"delegate","tier":"prose","project":"r"}' >  "$met2"
printf '%s\n' '{"ts":"2026-05-10T10:00:01Z","source":"delegate"'                                 >> "$met2"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --metrics-file "$met2" --state-file "$state2" --loki-url http://x >/dev/null 2>&1 || EC=$?
assert_eq "1" "$EC" "T6: malformed row -> exit 1"
if [[ -f "$state2" ]]; then echo "  FAIL  T6: watermark must NOT advance on a malformed batch"; fail=$((fail+1)); else echo "  PASS  T6: watermark not advanced on a malformed batch"; pass=$((pass+1)); fi

# --- T7: valid rows with no usable ts are skipped (advance, no push) --------
met3="$tmp/m3.jsonl"; state3="$tmp/state3"; body3="$tmp/body3.json"
make_mock_curl "$tmp" "$body3"
printf '%s\n' '{"source":"delegate","tier":"prose","project":"r"}' > "$met3"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --metrics-file "$met3" --state-file "$state3" --loki-url http://x 2>&1) || EC=$?
assert_eq "0" "$EC" "T7: no-ts rows -> exit 0"
assert_contains "no pushable entries" "$out" "T7: warns about skipped rows"
assert_eq "1" "$(cat "$state3" 2>/dev/null)" "T7: watermark advanced past unsyncable rows"
if [[ -f "$body3" ]]; then echo "  FAIL  T7: nothing should have been pushed"; fail=$((fail+1)); else echo "  PASS  T7: no push body written"; pass=$((pass+1)); fi

# --- T8: response tempfile is mktemp-based and cleaned up on exit -----------
# (was a predictable /tmp/loki_push_resp.$$ path; now mktemp + EXIT trap).
# Point TMPDIR at a fresh dir so any leaked mktemp file is visible.
tmpd="$tmp/tmpd"; mkdir -p "$tmpd"
state4="$tmp/state4"; body4="$tmp/body4.json"
make_mock_curl "$tmp" "$body4"
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" TMPDIR="$tmpd" \
  bash "$SCRIPT" --full --metrics-file "$met" --state-file "$state4" --loki-url http://x >/dev/null 2>&1 || EC=$?
assert_eq "0" "$EC" "T8: push run exits 0 with TMPDIR override"
leftover=$(ls -A "$tmpd" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover" "T8: no tempfile leaked in TMPDIR after exit"

# --- T9: ns timestamp is content-derived, stable across file POSITION --------
# The hardening: a row re-pushed at a different line number must get the SAME
# ns, so re-syncing a rewritten/reordered file does not duplicate it. The old
# line-number-as-ns scheme failed this and caused the 2026-06-19 feedback
# doubling in the local Loki.
row9='{"ts":"2026-05-10T11:11:11Z","source":"delegate","tier":"prose","estimated_tokens_avoided":5,"exit_status":0,"project":"repo-z"}'
met9a="$tmp/m9a.jsonl"; met9b="$tmp/m9b.jsonl"
state9a="$tmp/s9a"; state9b="$tmp/s9b"; body9a="$tmp/b9a.json"; body9b="$tmp/b9b.json"
printf '%s\n' "$row9" > "$met9a"                                     # row at line 1
printf '%s\n%s\n%s\n' \
  '{"ts":"2026-05-10T11:00:00Z","source":"delegate","tier":"code","project":"a"}' \
  '{"ts":"2026-05-10T11:00:01Z","source":"delegate","tier":"code","project":"b"}' \
  "$row9" > "$met9b"                                                 # SAME row at line 3
make_mock_curl "$tmp" "$body9a"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --full --metrics-file "$met9a" --state-file "$state9a" --loki-url http://x >/dev/null 2>&1
make_mock_curl "$tmp" "$body9b"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --full --metrics-file "$met9b" --state-file "$state9b" --loki-url http://x >/dev/null 2>&1
ns9a=$(jq -r '.streams[].values[] | select((.[1]|fromjson).project=="repo-z") | .[0]' "$body9a")
ns9b=$(jq -r '.streams[].values[] | select((.[1]|fromjson).project=="repo-z") | .[0]' "$body9b")
assert_eq "$ns9a" "$ns9b" "T9: same row -> same ns regardless of file position (re-sync idempotent)"

rm -rf "$tmp"
echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
