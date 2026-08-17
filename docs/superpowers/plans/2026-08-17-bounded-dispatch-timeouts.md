# Bounded Dispatch Timeouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every outbound HTTP call in the skill a wall-clock ceiling, so a hung or wedged backend can no longer block the caller's pipeline indefinitely.

**Architecture:** Five `curl` invocations across three scripts currently run with no `--max-time` and no `--connect-timeout`. Each gains both flags, sourced from a per-script environment variable with an evidence-backed default. No control flow changes: the existing `status`-based failure paths already handle a non-zero curl exit, so a timeout surfaces through the same branch that a connection refusal does today. The only additive behaviour is a recovery hint that recognises curl exit 28 (`--max-time` fired) and names the knob to raise, mirroring the pattern the recipe canary already uses at `scripts/delegate.sh:1117`.

**Tech Stack:** bash 3.2 (macOS system bash), `curl`, `jq`, the repo's hand-rolled assertion harness in `tests/` (`assert_eq` / `assert_contains`, mock binaries on a restricted `PATH` under `env -i`).

**Spec:** `docs/superpowers/specs/2026-08-17-provider-agnostic-backend-design.md` (this plan implements the "PR 1 — unbounded curls" stage, described at `:257-261`)

## Global Constraints

- Target bash is macOS system bash **3.2**. No associative arrays, no `${var^^}`, no `mapfile`, no `&>>`.
- Every script under `scripts/` runs with `set -euo pipefail` or `set -u`; check the target file's header before adding a bare command substitution that may fail.
- `--max-time` bounds the **whole** request including cold model load, not just generation. Every default below is chosen against that fact.
- Tests must stay hermetic. `tests/test-delegate.sh` runs each case under `env -i PATH="$tmp:$SAFE_PATH"` with `SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"`. New mocks follow the existing mock-binary-on-restricted-PATH pattern; no test may issue a real network request.
- Do not reformat or reorder unrelated lines. Diffs in these files are reviewed closely.
- Match the surrounding comment density. These scripts are heavily commented with the *why*; a new flag whose default needs justification gets a comment, a mechanical one does not.
- Conventional Commit messages. The 600 s evidence goes in the Task 1 commit body.

---

### Task 1: Bound the two delegate.sh dispatch curls

The dispatch POST is the call that matters. Recorded history contains a `long-context` runaway that ran **11,582,773 ms** (3.2 hours) producing 961,344 output chars with no way to stop it short of killing the process.

**Files:**
- Modify: `scripts/delegate.sh` — env-var doc block (insert after the `DELEGATE_PREFLIGHT_TIMEOUT` entry ending at `:135`), the two dispatch curls at `:1207` and `:1239`, and the dispatch-failure guidance at `:1274-1281`
- Test: `tests/test-delegate.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the environment variable `DELEGATE_REQUEST_TIMEOUT` (integer seconds, default `600`) and the shell variable `request_timeout` inside `dispatch_to_model()`. Tasks 2 and 3 deliberately do **not** reuse this variable; they define their own, for the reasons stated in each.

- [x] **Step 1: Write the failing test**

The existing mocks in `tests/test-delegate.sh` sniff the request *payload* (stdin). Nothing sniffs `curl`'s argv, so add a helper that does. Insert it immediately after `make_mock_curl_think()` ends (currently `:133`), keeping the mock helpers grouped:

```bash
make_mock_curl_argv() {
  # Mock curl that records its own argv to $2 as one space-joined line, then
  # behaves like make_mock_curl_ok. Lets a test assert on the flags
  # delegate.sh passes rather than on the payload it sends. Space-joined so a
  # test can assert the flag and its value together ("--max-time 600") rather
  # than matching a bare "600" that any other argument could satisfy.
  local dir="$1" argv_file="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${argv_file}"
out_file=""
write_out=""
saw_probe=0
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *"/v1/models"*) saw_probe=1; shift ;;
    *) shift ;;
  esac
done
if (( saw_probe == 1 )); then exit 7; fi
cat > /dev/null
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
  chmod +x "$dir/curl"
}
```

Then append these four cases at the end of the file, immediately before the final pass/fail tally. Mirror the surrounding style: a numbered comment, a fresh `tmp`, mocks, an `env -i` invocation.

```bash
# 34. --max-time / --connect-timeout are passed on the Ollama dispatch curl,
# defaulting to 600 s (see the DELEGATE_REQUEST_TIMEOUT header entry).
tmp=$(mktemp -d)
argv="$tmp/argv.txt"
make_mock_ollama "$tmp"
make_mock_curl_argv "$tmp" "$argv"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND=ollama \
  bash "$SCRIPT" prose "hello" 2>&1) || true
argv_text=$(cat "$argv" 2>/dev/null)
assert_contains "--max-time 600" "$argv_text" "ollama dispatch defaults to 600s"
assert_contains "--connect-timeout" "$argv_text" "ollama dispatch passes --connect-timeout"
rm -rf "$tmp"

# 35. DELEGATE_REQUEST_TIMEOUT overrides the default.
tmp=$(mktemp -d)
argv="$tmp/argv.txt"
make_mock_ollama "$tmp"
make_mock_curl_argv "$tmp" "$argv"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND=ollama \
  DELEGATE_REQUEST_TIMEOUT=42 \
  bash "$SCRIPT" prose "hello" 2>&1) || true
argv_text=$(cat "$argv" 2>/dev/null)
assert_contains "--max-time 42" "$argv_text" "DELEGATE_REQUEST_TIMEOUT overrides the default"
rm -rf "$tmp"

# 36. The MLX dispatch curl gets the same bounds. The mock exits 7 on
# /v1/models, so pin the backend rather than relying on the auto probe.
tmp=$(mktemp -d)
argv="$tmp/argv.txt"
make_mock_ollama "$tmp"
make_mock_curl_argv "$tmp" "$argv"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND=mlx \
  bash "$SCRIPT" prose "hello" 2>&1) || true
argv_text=$(cat "$argv" 2>/dev/null)
assert_contains "--max-time 600" "$argv_text" "mlx dispatch defaults to 600s"
assert_contains "--connect-timeout" "$argv_text" "mlx dispatch passes --connect-timeout"
rm -rf "$tmp"

# 37. A timeout (curl exit 28) names the knob to raise, rather than sending
# the caller to the generic daemon-check text.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "curl: (28) Operation timed out" >&2
exit 28
EOF
chmod +x "$tmp/curl"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND=ollama \
  bash "$SCRIPT" prose "hello" 2>&1) || EC=$?
assert_contains "DELEGATE_REQUEST_TIMEOUT" "$out" "timeout guidance names the knob"
rm -rf "$tmp"
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-delegate.sh 2>&1 | grep -E "FAIL|^(pass|fail|PASS:|FAIL:)"`

Expected: the six new `assert_contains` lines FAIL (the argv file contains no `--max-time`, no `--connect-timeout`, and the exit-28 case prints only the generic daemon text). Every pre-existing case still passes. If any pre-existing case now fails, stop — the new helper has leaked into an earlier test's `$tmp`.

- [x] **Step 3: Add the environment variable to the header doc block**

Insert immediately after the `DELEGATE_PREFLIGHT_TIMEOUT` entry (which ends at `:135` with the `Set 0 to disable the canary.` line). Match the existing column alignment exactly — the `#` continuation column is 44:

```bash
#   DELEGATE_REQUEST_TIMEOUT=<s>            # default 600. curl --max-time on
#                                           #   the dispatch POST, paired with
#                                           #   --connect-timeout 5. Bounds the
#                                           #   whole request including cold
#                                           #   model load, not just
#                                           #   generation — 600 preserves
#                                           #   every genuine call in recorded
#                                           #   history (largest: 505 s, of
#                                           #   which 504.6 s was load) while
#                                           #   killing the 3.2-hour runaway.
```

- [x] **Step 4: Resolve the timeout inside dispatch_to_model()**

`dispatch_to_model()` opens at `:1192`. Add the resolution as the first statement in the function body, above the `if [[ "$backend" == "ollama" ]]` at `:1194`:

```bash
  # Bounds the whole request including cold model load. Deliberately not
  # validated: a non-numeric value makes curl exit 2 with its own clear
  # "expected a proper numerical parameter" message, which is a better
  # error than anything a hand-rolled check would print.
  request_timeout="${DELEGATE_REQUEST_TIMEOUT:-600}"
```

Not `local`. Step 6 reads this variable from the caller's scope, and the
function already sets `status`, `output`, `payload` and `ttfb_s` as globals —
verified: `grep -n 'local status\|local output\|local ttfb_s\|local payload'
scripts/delegate.sh` returns no matches.

- [x] **Step 5: Add the flags to both dispatch curls**

At `:1207`, change:

```bash
  ttfb_s=$(curl -sS --fail -X POST "$ollama_host/api/generate" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
```

to:

```bash
  ttfb_s=$(curl -sS --fail --max-time "$request_timeout" --connect-timeout 5 \
    -X POST "$ollama_host/api/generate" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
```

At `:1239`, change:

```bash
  ttfb_s=$(curl -sS --fail -X POST "$mlx_host/v1/chat/completions" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
```

to:

```bash
  ttfb_s=$(curl -sS --fail --max-time "$request_timeout" --connect-timeout 5 \
    -X POST "$mlx_host/v1/chat/completions" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
```

Both keep `status=$?` on the following line unchanged. `--connect-timeout 5` is a literal rather than a knob because connect failure and generation stall deserve different bounds and only the latter varies by workload.

- [x] **Step 6: Teach the dispatch-failure guidance about exit 28**

The block at `:1273-1282` currently prints the same three lines for every non-zero status. Insert a timeout-specific line, keeping the existing three intact:

```bash
if (( status != 0 )); then
  {
    echo "delegate: dispatch failed (curl exit $status) — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    if (( status == 28 )); then
      echo "         the request did not return within ${request_timeout}s (curl --max-time fired)"
      echo "         - raise DELEGATE_REQUEST_TIMEOUT if a cold model load is suspected"
      echo "         - or pick a smaller model for this tier"
    fi
    echo "         check the backend daemon (ollama serve / mlx_lm.server) and OLLAMA_HOST / MLX_HOST — see the README Troubleshooting section"
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
fi
```

This reads `request_timeout` from the caller's scope, which works because Step 4 sets it without `local`, matching how the same function already sets `status` and `output`.

- [x] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test-delegate.sh 2>&1 | tail -5`

Expected: `556 passed, 0 failed` becomes `562 passed, 0 failed` (556 existing plus the six new assertions). Any pre-existing failure is a regression — fix it before continuing.

- [x] **Step 8: Run the rest of the suite for regressions**

Run: `bash tests/run-tests.sh 2>&1 | tail -3`
Expected: `110 passed, 0 failed`, unchanged.

Run: `bash tests/test-delegate-boundary-hook.sh 2>&1 | tail -3`
Expected: `134 passed, 0 failed`, unchanged.

Run: `bash tests/test-delegate-feedback.sh 2>&1 | tail -3`
Expected: `226 passed, 0 failed`, unchanged.

- [x] **Step 9: Verify against the real backend**

The tests prove the flags are passed; this proves they do not break a live call. With `mlx_lm.server` running on `:8080`:

Run: `DELEGATE_BACKEND=mlx bash scripts/delegate.sh prose "Say the single word: ok"`
Expected: normal output, no timeout.

Run: `DELEGATE_BACKEND=mlx DELEGATE_REQUEST_TIMEOUT=1 bash scripts/delegate.sh prose "Write 2000 words about bash"`
Expected: exit non-zero, stderr contains `did not return within 1s (curl --max-time fired)` and `raise DELEGATE_REQUEST_TIMEOUT`.

- [x] **Step 10: Commit**

```bash
git add scripts/delegate.sh tests/test-delegate.sh
git commit -m "fix(delegate): bound the dispatch POST with DELEGATE_REQUEST_TIMEOUT

The dispatch curl had no --max-time, so a wedged backend blocked the
caller indefinitely. Recorded history contains an 11,582,773 ms
long-context runaway producing 961,344 output chars.

Default 600s, chosen over 1376 successful rows: p50 3,726ms, p95
40,095ms, p99 80,180ms, p99.9 232,503ms. The largest genuine call is
505,073ms, of which 504,601ms is cold model load and 472ms is
generation, so --max-time must cover load. 600s clears that with 19%
margin; 300s would have severed two real calls.

Refs: #363"
```

---

### Task 2: Bound the embed.sh embeddings curl

**Files:**
- Modify: `scripts/embed.sh` — env-var doc block (after the `DELEGATE_EMBED_MAX_CHARS` entry at `:28`) and the curl at `:192`
- Test: `tests/test-embed.sh`

**Interfaces:**
- Consumes: nothing from Task 1. This task is independently revertible.
- Produces: the environment variable `DELEGATE_EMBED_TIMEOUT` (integer seconds, default `60`).

A separate variable from Task 1's is correct here, not duplication. Embedding latency is three orders of magnitude below generation — measured over 129 recorded embedding rows: p50 144 ms, p95 202 ms, p99 2,574 ms, max 5,486 ms — and `scripts/semantic-search.sh` calls this script once per chunk, so a 600 s ceiling per chunk would let a wedged daemon stall a search for hours. 60 s is roughly 11x the observed maximum.

- [x] **Step 1: Write the failing test**

`tests/test-embed.sh` already has `make_mock_curl_ok` at `:48-70`. Add an argv-recording variant directly after it:

```bash
make_mock_curl_argv() {
  # Records curl's argv to $2 so a test can assert on flags, then returns a
  # canned embeddings body like make_mock_curl_ok.
  local dir="$1" argv_file="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${argv_file}"
out_file=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
body='{"embeddings":[[0.1,0.2,0.3]]}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
EOF
  chmod +x "$dir/curl"
}
```

Append two cases before the final tally, following the file's existing case style:

```bash
# 18. The embeddings POST is bounded, defaulting to 60 s.
tmp=$(mktemp -d)
argv="$tmp/argv.txt"
make_mock_ollama "$tmp"
make_mock_curl_argv "$tmp" "$argv"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" "hello world" 2>&1) || true
argv_text=$(cat "$argv" 2>/dev/null)
assert_contains "--max-time 60" "$argv_text" "embed defaults to 60s"
assert_contains "--connect-timeout" "$argv_text" "embed passes --connect-timeout"
rm -rf "$tmp"

# 19. DELEGATE_EMBED_TIMEOUT overrides the default.
tmp=$(mktemp -d)
argv="$tmp/argv.txt"
make_mock_ollama "$tmp"
make_mock_curl_argv "$tmp" "$argv"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_EMBED_TIMEOUT=7 \
  bash "$SCRIPT" "hello world" 2>&1) || true
argv_text=$(cat "$argv" 2>/dev/null)
assert_contains "--max-time 7" "$argv_text" "DELEGATE_EMBED_TIMEOUT overrides the default"
rm -rf "$tmp"
```

Before running, confirm `$SCRIPT` and the invocation shape match what the rest of `tests/test-embed.sh` uses — read one existing case and copy its argument order rather than assuming the single-positional form above.

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-embed.sh 2>&1 | grep FAIL`
Expected: the three new assertions FAIL. No pre-existing case fails.

- [x] **Step 3: Add the environment variable to the header doc block**

Insert after the `DELEGATE_EMBED_MAX_CHARS` entry at `:28`, matching that block's narrower alignment (the `#` continuation column in `embed.sh` is 41, not `delegate.sh`'s 44 — copy the neighbouring line's spacing rather than this plan's):

```bash
#   DELEGATE_EMBED_TIMEOUT=<s>            # default 60. curl --max-time on the
#                                         #   embeddings POST. Far below the
#                                         #   dispatch ceiling because
#                                         #   embedding is fast (129 recorded
#                                         #   rows: p50 144ms, max 5,486ms)
#                                         #   and semantic-search calls this
#                                         #   once per chunk.
```

- [x] **Step 4: Add the flags to the curl**

At `:192`, change:

```bash
curl -sS --fail -X POST "$ollama_host/api/embed" -d @- \
  -o "$body_file" <<< "$payload"
```

to:

```bash
curl -sS --fail --max-time "${DELEGATE_EMBED_TIMEOUT:-60}" --connect-timeout 5 \
  -X POST "$ollama_host/api/embed" -d @- \
  -o "$body_file" <<< "$payload"
```

Inlined rather than assigned to a variable because it has exactly one use site, unlike Task 1's, which is referenced again by the recovery text.

`status=$?` on the following line is unchanged, and the existing `if (( status != 0 ))` block at `:199` already logs a metric row with the curl status, so a timeout is recorded as `exit_status: 28` with no further change.

- [x] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-embed.sh 2>&1 | tail -3`
Expected: `48 passed, 0 failed` becomes `51 passed, 0 failed`.

- [x] **Step 6: Verify against the real backend**

Run: `bash scripts/embed.sh "hello world" | head -c 120`
Expected: a JSON embeddings array, unchanged behaviour.

Run: `DELEGATE_EMBED_TIMEOUT=0.001 bash scripts/embed.sh "hello world"; echo "exit=$?"`
Expected: `exit=28`. If curl instead rejects `0.001` outright, use a value of `1` against a deliberately stopped Ollama and expect exit 28 or 7.

- [x] **Step 7: Commit**

```bash
git add scripts/embed.sh tests/test-embed.sh
git commit -m "fix(embed): bound the embeddings POST with DELEGATE_EMBED_TIMEOUT

Default 60s. Measured over 129 embedding rows: p50 144ms, p95 202ms,
p99 2,574ms, max 5,486ms. Lower than the dispatch ceiling because
semantic-search.sh calls this once per chunk.

Refs: #363"
```

---

### Task 3: Bound the Loki sync curls

**Files:**
- Modify: `scripts/sync-metrics-to-loki.sh` — env-var doc block (after the `DELEGATE_LOKI_STATE` entry at `:24`), the push at `:178`, and the flush at `:189`
- Test: `tests/test-sync-metrics-to-loki.sh`

**Interfaces:**
- Consumes: nothing. Independently revertible.
- Produces: the environment variable `DELEGATE_LOKI_TIMEOUT` (integer seconds, default `30`).

The two curls get different treatment. The push at `:178` carries the payload and its failure is reported to the caller, so it takes the full `DELEGATE_LOKI_TIMEOUT`. The flush at `:189` is explicitly best-effort — it already ends in `|| true` and discards its output — so it takes a fixed 5 s. A best-effort call that can hang for 30 s is the same bug in a smaller costume.

- [x] **Step 1: Write the failing test**

This file's conventions differ from the other two: it drives the script through
CLI flags (`--metrics-file`, `--state-file`, `--loki-url`) rather than
environment variables, labels cases `Tn:` rather than `# N.`, and already has a
`make_mock_curl "$dir" "$body"` at `:22-38` that captures the `--data-binary`
payload. Follow those conventions.

The existing mock discards argv, and the success path fires curl twice (push
then flush), so a mock that overwrites would only ever record the flush. Add a
variant that **appends** argv, immediately after `make_mock_curl` ends at `:38`:

```bash
make_mock_curl_argv() {
  # As make_mock_curl, but also appends each invocation's argv to $3 as a
  # single space-joined line. Appends rather than overwrites because the
  # success path calls curl twice (push, then the best-effort flush), and
  # the assertions below need both lines.
  local dir="$1" body="$2" argv_file="$3"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${argv_file}"
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--data-binary" ]]; then
    if [[ "\$a" == "@-" ]]; then cat > "$body"; else printf '%s' "\$a" > "$body"; fi
  fi
  prev="\$a"
done
echo -n "204"
exit 0
EOF
  chmod +x "$dir/curl"
}
```

Then append these cases before the final tally, reusing the fixture shape the
file already uses (a `$met` metrics file and a `$state` watermark, both under a
fresh `$tmp`):

```bash
# --- T-timeout: push and flush are both bounded ----------------------------
tmp=$(mktemp -d)
body="$tmp/body.json"
argv="$tmp/argv.txt"
make_mock_curl_argv "$tmp" "$body" "$argv"
met="$tmp/m.jsonl"
state="$tmp/state"
cat > "$met" <<'EOF'
{"ts":"2026-05-10T10:00:00Z","source":"delegate","tier":"prose","estimated_tokens_avoided":42,"exit_status":0,"project":"repo-x"}
EOF
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" --full --metrics-file "$met" --state-file "$state" --loki-url http://x 2>&1)
push_line=$(grep -- '/loki/api/v1/push' "$argv")
flush_line=$(grep -- '/flush' "$argv")
assert_contains "--max-time 30" "$push_line" "T-timeout: push defaults to 30s"
assert_contains "--connect-timeout 5" "$push_line" "T-timeout: push sets --connect-timeout"
assert_contains "--max-time 5" "$flush_line" "T-timeout: flush uses a fixed 5s"
rm -rf "$tmp"

# --- T-timeout-override: DELEGATE_LOKI_TIMEOUT moves the push bound only ---
tmp=$(mktemp -d)
body="$tmp/body.json"
argv="$tmp/argv.txt"
make_mock_curl_argv "$tmp" "$body" "$argv"
met="$tmp/m.jsonl"
state="$tmp/state"
cat > "$met" <<'EOF'
{"ts":"2026-05-10T10:00:00Z","source":"delegate","tier":"prose","estimated_tokens_avoided":42,"exit_status":0,"project":"repo-x"}
EOF
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_LOKI_TIMEOUT=9 \
  bash "$SCRIPT" --full --metrics-file "$met" --state-file "$state" --loki-url http://x 2>&1)
push_line=$(grep -- '/loki/api/v1/push' "$argv")
flush_line=$(grep -- '/flush' "$argv")
assert_contains "--max-time 9" "$push_line" "T-timeout-override: push honours the knob"
assert_contains "--max-time 5" "$flush_line" "T-timeout-override: flush stays fixed at 5s"
rm -rf "$tmp"
```

`grep` on the argv file is what separates the two invocations, which is why the
mock appends one space-joined line per call. `assert_contains "--max-time 30"`
(with the value) rather than bare `--max-time` is what makes the two cases
distinguish push from flush.

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-sync-metrics-to-loki.sh 2>&1 | grep FAIL`
Expected: the new assertions FAIL. No pre-existing case fails.

- [x] **Step 3: Add the environment variable to the header doc block**

Insert after the `DELEGATE_LOKI_STATE` entry at `:24`, matching that block's two-column prose style (it differs from both other scripts — copy the neighbouring line):

```bash
#   DELEGATE_LOKI_TIMEOUT    curl --max-time on the push. Default 30. The
#                            best-effort flush uses a fixed 5s.
```

- [x] **Step 4: Add the flags to the push**

At `:178`, change:

```bash
http_code=$(printf '%s' "$payload" | curl -s -o "$resp_file" -w '%{http_code}' \
  -X POST "${loki_url%/}/loki/api/v1/push" \
  -H 'Content-Type: application/json' --data-binary @-)
```

to:

```bash
http_code=$(printf '%s' "$payload" | curl -s -o "$resp_file" -w '%{http_code}' \
  --max-time "${DELEGATE_LOKI_TIMEOUT:-30}" --connect-timeout 5 \
  -X POST "${loki_url%/}/loki/api/v1/push" \
  -H 'Content-Type: application/json' --data-binary @-)
```

On a timeout curl writes no `%{http_code}`, so `$http_code` is empty. The existing test at `:180` is `[[ "$http_code" == "204" || "$http_code" == "200" ]]`, which an empty string already fails, routing to the `else` branch that leaves the watermark unchanged and exits 1. That is the correct behaviour for a timed-out push and needs no change — confirm it by reading `:180-196` rather than trusting this paragraph.

- [x] **Step 5: Add the flags to the flush**

At `:189`, change:

```bash
  curl -s -o /dev/null -X POST "${loki_url%/}/flush" 2>/dev/null || true
```

to:

```bash
  curl -s -o /dev/null --max-time 5 --connect-timeout 5 \
    -X POST "${loki_url%/}/flush" 2>/dev/null || true
```

Fixed 5 s, not the knob: this call is already best-effort and its result is discarded, so there is no workload that justifies waiting longer.

- [x] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-sync-metrics-to-loki.sh 2>&1 | tail -3`
Expected: `24 passed, 0 failed` becomes `29 passed, 0 failed` (24 existing plus the five new assertions).

- [x] **Step 7: Run the full suite**

Run each and expect the counts unchanged from Task 1 Step 8, plus this task's additions:

```bash
bash tests/test-delegate.sh 2>&1 | tail -2
bash tests/run-tests.sh 2>&1 | tail -2
bash tests/test-embed.sh 2>&1 | tail -2
bash tests/test-delegate-feedback.sh 2>&1 | tail -2
bash tests/test-delegate-boundary-hook.sh 2>&1 | tail -2
bash tests/test-prompts-library.sh 2>&1 | tail -2
bash tests/test-metrics-summary.sh 2>&1 | tail -2
bash tests/test-sync-metrics-to-loki.sh 2>&1 | tail -2
```

- [x] **Step 8: Commit**

```bash
git add scripts/sync-metrics-to-loki.sh tests/test-sync-metrics-to-loki.sh
git commit -m "fix(loki): bound the metrics push and flush curls

Push takes DELEGATE_LOKI_TIMEOUT (default 30s); the best-effort flush
takes a fixed 5s since its result is discarded. A timed-out push leaves
the watermark unchanged and exits 1, matching the existing HTTP-error
path.

Refs: #363"
```

---

## Out of Scope

Named explicitly so an executor does not drift into PR 2:

- The empty-output guard. The spec defers it deliberately (`:273-276`): `finish_reason` has two spellings today (`.done_reason` on Ollama, `.choices[0].finish_reason` on MLX), so implementing it now means per-branch code and a fixture PR 2 immediately deletes.
- `DELEGATE_BASE_URL`, provider-major resolution, and the removal of `DELEGATE_BACKEND`. All PR 2.
- Renaming `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT` to `DELEGATE_PROBE_TIMEOUT`. It belongs with the resolution rework in PR 2; renaming it here would touch `tests/run-tests.sh:943` for no shippable benefit.
- `SKILL.md`, README, and ADR updates. All PR 3.
