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
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --metrics-file "$met" --state-file "$state" --loki-url http://x >/dev/null 2>&1
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

rm -rf "$tmp"
echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
