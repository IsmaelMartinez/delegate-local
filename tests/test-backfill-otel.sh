#!/usr/bin/env bash
# Unit tests for scripts/backfill-otel.sh.
# Builds synthetic metrics JSONL fixtures in $tmp, mocks curl on a restricted
# PATH so OTel POSTs are captured to a sniff file rather than actually
# escaping the host, and asserts the per-row progress lines, final summary,
# idempotency, and JSONL mutation semantics.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/backfill-otel.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

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

# Mock curl that captures every POST body to "$bodies_dir/N.json" (one file
# per call so two POSTs in the same run can both be inspected) and writes
# the argv to $invocations_log. Per-call exit code controlled by $behaviour:
# "ok" → 0, "fail" → 22, "timeout" → 28.
#
# The mock is OTel-only: backfill never calls Ollama or MLX, so we don't
# need the auto-probe dance the delegate.sh mock has.
make_mock_curl() {
  local dir="$1" bodies_dir="$2" invocations_log="$3" behaviour="${4:-ok}"
  mkdir -p "$bodies_dir"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${invocations_log}"
# Read stdin into a per-call body file. Use a counter file to avoid clobber.
counter_file="${bodies_dir}/.counter"
n=0
if [[ -f "\$counter_file" ]]; then
  n=\$(cat "\$counter_file")
fi
n=\$((n + 1))
echo "\$n" > "\$counter_file"
cat > "${bodies_dir}/\${n}.json"
case "${behaviour}" in
  fail) exit 22 ;;
  timeout) exit 28 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/curl"
}

# ---------------------------------------------------------------------------
# 1. No OTel endpoint and not --dry-run → exits 1 with clear error.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
EOF
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 1 "$EC" "T1: endpoint unset (no --dry-run) → exit 1"
assert_contains "DELEGATE_OTEL_ENDPOINT" "$out" "T1: error names the missing env var"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 2. --dry-run with no endpoint set → still works, no curl calls, per-row
#    progress emitted to stderr.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
{"ts":"2026-05-22T10:01:00Z","source":"feedback","ref_ts":"2026-05-22T10:00:00Z","kept":true,"reason":"used"}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --dry-run --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T2: --dry-run no endpoint → exits 0"
# Two OK lines, one for each row.
ok_count=$(echo "$out" | grep -c '^OK ')
assert_eq 2 "$ok_count" "T2: --dry-run prints one OK line per processable row"
# No curl calls at all (the mock would have logged one per call).
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 0 "$curl_count" "T2: --dry-run makes zero curl calls"
# Final summary line names the count.
assert_contains "backfill: 2 rows, 2 sent, 0 skipped, 0 errored" "$out" "T2: --dry-run summary line"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 3. Already-exported row (otel_trace_id present) → SKIP. No curl call.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8,"otel_trace_id":"aaaa1111bbbb2222cccc3333dddd4444","otel_span_id":"feedface12345678"}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T3: already-exported row → exits 0"
assert_contains "SKIP ts=2026-05-22T10:00:00Z" "$out" "T3: SKIP line emitted"
assert_contains "already exported by JSONL" "$out" "T3: SKIP names the reason"
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 0 "$curl_count" "T3: zero curl calls for already-exported row"
assert_contains "backfill: 1 rows, 0 sent, 1 skipped, 0 errored" "$out" "T3: summary counts SKIP"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 4. Pre-exporter row (no otel_trace_id) → POSTed with deterministic IDs.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b","prompt_chars":80,"context_chars":100,"output_chars":50,"duration_ms":5000,"queue_wait_ms":100,"generation_ms":4900,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T4: pre-exporter row → exits 0"
assert_contains "OK ts=2026-05-22T10:00:00Z (delegate)" "$out" "T4: OK line emitted"
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 1 "$curl_count" "T4: exactly one curl call for the row"
# Inspect the POSTed body.
body=$(cat "$bodies/1.json")
# Compute the expected deterministic IDs for (ts, source) = (2026-05-22T10:00:00Z, delegate)
expected_trace=$(perl -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex("2026-05-22T10:00:00Z|delegate"), 0, 32)')
expected_span=$(perl -MDigest::SHA=sha1_hex -e 'print substr(sha1_hex("2026-05-22T10:00:00Z|delegate"), 0, 16)')
trace_in_body=$(echo "$body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId')
span_in_body=$(echo "$body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId')
assert_eq "$expected_trace" "$trace_in_body" "T4: trace_id is deterministic from (ts, source)"
assert_eq "$expected_span" "$span_in_body" "T4: span_id is deterministic from (ts, source)"
# Schema sanity: gen_ai.* attributes present.
assert_contains '"gen_ai.request.model"' "$body" "T4: gen_ai.request.model attribute"
assert_contains '"qwen3.6:35b"' "$body" "T4: model value forwarded"
assert_contains '"delegate.tier"' "$body" "T4: delegate.tier attribute"
assert_contains '"prose"' "$body" "T4: tier value forwarded"
# Privacy: no content attributes present.
assert_not_contains '"gen_ai.prompt"' "$body" "T4: no gen_ai.prompt (privacy invariant)"
assert_not_contains '"gen_ai.completion"' "$body" "T4: no gen_ai.completion"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 5. Feedback row → POSTed as feedback span with parent IDs derived from
#    the parent delegate row's deterministic IDs.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b","prompt_chars":80,"context_chars":100,"output_chars":50,"duration_ms":5000,"queue_wait_ms":100,"generation_ms":4900,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-22T10:01:00Z","source":"feedback","ref_ts":"2026-05-22T10:00:00Z","kept":false,"reason":"had to rewrite"}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T5: feedback row → exits 0"
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 2 "$curl_count" "T5: two curl calls (delegate + feedback)"
# The second POST is the feedback span.
fb_body=$(cat "$bodies/2.json")
expected_parent_trace=$(perl -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex("2026-05-22T10:00:00Z|delegate"), 0, 32)')
expected_parent_span=$(perl -MDigest::SHA=sha1_hex -e 'print substr(sha1_hex("2026-05-22T10:00:00Z|delegate"), 0, 16)')
fb_span_kind=$(echo "$fb_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].kind')
assert_eq "1" "$fb_span_kind" "T5: feedback span kind=1 (INTERNAL)"
fb_verdict=$(echo "$fb_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.feedback.verdict"))
  | .[0].value.stringValue')
assert_eq "miss" "$fb_verdict" "T5: feedback verdict is 'miss' (from kept:false)"
# Track F (#158) default: feedback reason is content and redacted unless
# DELEGATE_OTEL_INCLUDE_CONTENT=1. Assert the redaction holds end-to-end
# through the backfill path.
assert_not_contains '"delegate.feedback.reason"' "$fb_body" "T5: feedback reason redacted by default (Track F invariant)"
# Parent IDs are the deterministic ones the delegate POST also used.
links_trace=$(echo "$fb_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].traceId')
links_span=$(echo "$fb_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].spanId')
assert_eq "$expected_parent_trace" "$links_trace" "T5: feedback links[0].traceId = parent's deterministic trace_id"
assert_eq "$expected_parent_span" "$links_span" "T5: feedback links[0].spanId = parent's deterministic span_id"
# Parent attributes also present (belt-and-braces).
parent_trace_attr=$(echo "$fb_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.feedback.parent_trace_id"))
  | .[0].value.stringValue')
assert_eq "$expected_parent_trace" "$parent_trace_attr" "T5: parent_trace_id attribute matches links"
rm -rf "$tmp"

# T5b. DELEGATE_OTEL_INCLUDE_CONTENT=1 → feedback reason IS emitted.
# Confirms the backfill path honours the Track F opt-in alongside the
# default redaction; operators who already opted in for the live exporter
# get the same wire shape from the backfill.
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b","prompt_chars":80,"context_chars":100,"output_chars":50,"duration_ms":5000,"queue_wait_ms":100,"generation_ms":4900,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-22T10:01:00Z","source":"feedback","ref_ts":"2026-05-22T10:00:00Z","kept":false,"reason":"had to rewrite"}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T5b: include-content + feedback row → exits 0"
fb_body=$(cat "$bodies/2.json")
fb_reason=$(echo "$fb_body" | jq -r '
  .resourceSpans[0].scopeSpans[0].spans[0].attributes
  | map(select(.key == "delegate.feedback.reason"))
  | .[0].value.stringValue')
assert_eq "had to rewrite" "$fb_reason" "T5b: feedback reason emitted when DELEGATE_OTEL_INCLUDE_CONTENT=1"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 6. Idempotency: running the backfill twice in a row produces identical
#    span IDs (sha1-derived) because the deterministic ID derivation is
#    a pure function of (ts, source).
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies1="$tmp/bodies-run1"
bodies2="$tmp/bodies-run2"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies1" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b","prompt_chars":80,"context_chars":100,"output_chars":50,"duration_ms":5000,"queue_wait_ms":100,"generation_ms":4900,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T6: first backfill exits 0"
trace_run1=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId' < "$bodies1/1.json")
span_run1=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId' < "$bodies1/1.json")
# Swap the bodies dir for run 2 and re-run. The mock writes a fresh
# counter file so the bodies don't collide with run 1.
make_mock_curl "$tmp" "$bodies2" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T6: second backfill exits 0"
trace_run2=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId' < "$bodies2/1.json")
span_run2=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId' < "$bodies2/1.json")
assert_eq "$trace_run1" "$trace_run2" "T6: trace_id identical across re-runs (deterministic)"
assert_eq "$span_run1" "$span_run2" "T6: span_id identical across re-runs (deterministic)"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 7. --since filter: rows older than --since are skipped (not even emitted
#    as SKIP), newer rows are processed.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-20T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
{"ts":"2026-05-22T11:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --since "2026-05-22T10:00:00Z" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T7: --since filter exits 0"
# 2 rows match (10:00 and 11:00); the older 05-20 row is not even
# considered. Summary should say "2 rows, 2 sent".
assert_contains "backfill: 2 rows, 2 sent" "$out" "T7: --since filter counts only matching rows"
# The 05-20 row's ts should not appear in any progress line.
assert_not_contains "2026-05-20T10:00:00Z" "$out" "T7: pre-since row not in progress output"
# Two POSTs.
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 2 "$curl_count" "T7: two curl calls (matching rows only)"
rm -rf "$tmp"

# T7b. --since malformed → exit 2 with clear error.
tmp=$(mktemp -d)
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"q","prompt_chars":10,"context_chars":20,"output_chars":5,"duration_ms":1000,"queue_wait_ms":100,"generation_ms":900,"exit_status":0,"estimated_tokens_avoided":8}
EOF
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --since "2026-05-22" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 2 "$EC" "T7b: malformed --since → exit 2"
assert_contains "ISO 8601" "$out" "T7b: error names the expected format"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 8. --update-jsonl: after backfill, the JSONL rows have otel_trace_id /
#    otel_span_id appended; a subsequent backfill skips them via the
#    live-exported path.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies1="$tmp/bodies-run1"
bodies2="$tmp/bodies-run2"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies1" "$invocations" "ok"
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-22T10:00:00Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b","prompt_chars":80,"context_chars":100,"output_chars":50,"duration_ms":5000,"queue_wait_ms":100,"generation_ms":4900,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-22T10:01:00Z","source":"feedback","ref_ts":"2026-05-22T10:00:00Z","kept":true,"reason":"used"}
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --update-jsonl --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T8: --update-jsonl first run → exits 0"
# Verify the JSONL was updated: the delegate row now carries
# otel_trace_id / otel_span_id; the feedback row is unchanged.
delegate_line=$(grep -F '"source":"delegate"' "$tmp/m.jsonl" | head -1)
assert_contains '"otel_trace_id":' "$delegate_line" "T8: delegate row got otel_trace_id written back"
assert_contains '"otel_span_id":' "$delegate_line" "T8: delegate row got otel_span_id written back"
# IDs in the row match the deterministic derivation.
expected_trace=$(perl -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex("2026-05-22T10:00:00Z|delegate"), 0, 32)')
written_trace=$(echo "$delegate_line" | jq -r '.otel_trace_id')
assert_eq "$expected_trace" "$written_trace" "T8: written trace_id is the deterministic one"
# Feedback row stays as-is (no otel_trace_id field).
feedback_line=$(grep -F '"source":"feedback"' "$tmp/m.jsonl" | head -1)
assert_not_contains 'otel_trace_id' "$feedback_line" "T8: feedback row not mutated (recomputed each run)"
# Second run: delegate row should SKIP via the live-exported path.
make_mock_curl "$tmp" "$bodies2" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T8: second run after --update-jsonl → exits 0"
assert_contains "SKIP ts=2026-05-22T10:00:00Z" "$out" "T8: second run SKIPs the updated delegate row"
# Only one POST this time (the feedback span; the delegate row was skipped).
run2_curl_count=$(ls "$bodies2" 2>/dev/null | grep -c '\.json$') || run2_curl_count=0
assert_eq 1 "$run2_curl_count" "T8: second run only posts the feedback span (delegate skipped)"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 9. Missing metrics file → exit 1 with clear error.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/missing.jsonl" 2>&1) || EC=$?
assert_eq 1 "$EC" "T9: missing metrics file → exit 1"
assert_contains "metrics file not found" "$out" "T9: error names the missing-file case"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 9b. Empty JSONL → no-op (per issue #157 spec). Exits 0 with a summary
#     of "0 rows" and zero curl calls.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
bodies="$tmp/bodies"
invocations="$tmp/invocations"; : > "$invocations"
make_mock_curl "$tmp" "$bodies" "$invocations" "ok"
: > "$tmp/m.jsonl"  # empty file
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --metrics-file "$tmp/m.jsonl" 2>&1) || EC=$?
assert_eq 0 "$EC" "T9b: empty JSONL → exits 0"
assert_contains "backfill: 0 rows, 0 sent, 0 skipped, 0 errored" "$out" "T9b: empty JSONL → summary shows zero counts"
curl_count=$(grep -c '^curl' "$invocations" 2>/dev/null) || curl_count=0
assert_eq 0 "$curl_count" "T9b: empty JSONL → zero curl calls"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 10. Unknown flag → usage exit 2.
# ---------------------------------------------------------------------------
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --unknown-flag 2>&1) || EC=$?
assert_eq 2 "$EC" "T10: unknown flag → exit 2"
assert_contains "usage:" "$out" "T10: usage line printed on bad flag"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
