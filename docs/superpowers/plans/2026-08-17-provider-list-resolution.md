# Provider-List Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make any OpenAI-compatible endpoint usable as a delegate backend by setting one environment variable, without adding a third hardcoded backend branch.

**Verifiable goal — the whole plan succeeds if and only if these four commands behave as stated, with all three daemons running:**

1. `DELEGATE_BASE_URL="http://localhost:12434/engines/v1" bash scripts/delegate.sh prose "Say the single word: ok"` prints `ok`. Docker Model Runner is reached through the same code path as MLX, with no Docker-specific branch anywhere in the tree (`grep -ci docker scripts/*.sh` returns 0 outside comments).
2. `DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:8080/v1" bash scripts/pick-model.sh --dry-run prose` resolves to the MLX model and its trace names the dead first provider as skipped. Today an unreachable first choice exits 1 instead of trying the next.
3. `DELEGATE_BASE_URL="http://user:pass@localhost:8080/v1" bash scripts/pick-model.sh prose` exits 2 without contacting anything.
4. With `DELEGATE_BASE_URL` unset, all eight test suites pass at their current counts, unchanged: test-delegate 562, run-tests 110, test-embed 51, test-delegate-feedback 226, test-delegate-boundary-hook 134, test-prompts-library 288, test-metrics-summary 135, test-sync-metrics-to-loki 30.

Point 4 is the load-bearing one. It is what makes this phase safe to land: the new path is purely additive, so any regression in the existing behaviour shows up as a suite failure rather than as a subtle routing change.

**Architecture:** `DELEGATE_BASE_URL` holds a space-separated ordered list of OpenAI-compatible base URLs. When it is set, `pick-model.sh` probes each in order with `GET {base}/models`, takes the first provider that both answers and holds a model matching the tier's preference list, and prints the model; `delegate.sh` then posts to `{base}/chat/completions`. When it is unset, every existing code path runs byte-identically to today. The MLX dispatch branch already speaks the OpenAI shape, so it is generalised to take a base URL rather than duplicated.

**Tech Stack:** bash 3.2 (macOS system bash), `curl`, `jq`, the repo's hand-rolled assertion harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-08-17-provider-agnostic-backend-design.md`. This plan implements the resolution and dispatch half of the spec's "PR 2 — the collapse" (`:255-262`), and deliberately defers the removal half. See "Deviations from the spec" below, which records three factual corrections found while verifying the spec against the tree.

## Global Constraints

- Target bash is macOS system bash **3.2**. No associative arrays, no `${var^^}`, no `mapfile`.
- `pick-model.sh` runs under `set -euo pipefail` (`:40`). The probe must be called with an explicit failure branch (`if ! models=$(…); then continue; fi`); as a bare assignment a stopped first provider aborts resolution before the others are tried, which is the exact inverse of the intended fallthrough.
- Tests stay hermetic: `env -i` with `SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"` and mock binaries on a restricted PATH. `SAFE_PATH` contains the real `/usr/bin/curl`, so any new code path reachable under test must be covered by a mock or it will issue real localhost traffic and pass for the wrong reason.
- Do not reformat or reorder unrelated lines.
- Match the surrounding comment density: these scripts comment the *why*, and a default that needs justification gets a comment.
- Conventional Commit messages with a `Refs: #363` trailer.

## Deviations from the spec

Recorded here rather than silently applied. Each was verified against the tree or the running daemons on 2026-08-17.

**D1 — the removal of `DELEGATE_BACKEND` is deferred to a follow-up.** The spec bundles driver collapse, base-URL resolution, the empty-output guard, the `audit-models.sh` rework, the test-mock migration and `eval-skill-triggers.sh` into one PR. Measured blast radius of the removal alone: 76 `DELEGATE_BACKEND` references and 162 `make_mock_ollama` call sites across `tests/run-tests.sh`, `tests/test-delegate.sh` and `tests/test-embed.sh`, plus `scripts/audit-models.sh` (`:21,22,25,32,67`), `scripts/embed.sh` (`:141,150,154,182`) and `scripts/semantic-search.sh:23`. Landing that churn together with new resolution logic means a suite failure cannot be attributed to either. This plan adds the new path additively and proves it; the removal becomes a mechanical follow-up with no new logic in it.

**D2 — `embed.sh` does not use the idiom the spec cites.** Spec Decision 4 says the plan reuses "the `DELEGATE_BASE_URL=… bash "$pick" <tier>` idiom that already exists at `embed.sh:175`". The line is `embed.sh:182` and the idiom is `DELEGATE_BACKEND=ollama bash "$pick" embedding`. The *pattern* (pin the provider via an env var passed to `pick-model.sh`) exists; the variable does not. Under D1 this line is untouched by this plan and must be converted when `DELEGATE_BACKEND` is removed, or embedding resolution breaks.

**D4 — `--print-resolution` is reinstated as an internal surface.** The spec lists `--print-resolution` among the things cut. It is reinstated here for a mechanical reason found during self-review: `--print-backend` answers at `pick-model.sh:168`, deliberately *before* the tier argument is read at `:177`, because both backend surfaces are tier-independent and `scripts/audit-models.sh` calls them that way. Under a provider list the winning base URL is tier-*dependent* (a provider can be reachable yet hold no model for this tier), so `--print-backend` cannot answer it without restructuring a surface `audit-models.sh` depends on. The alternative, having `delegate.sh` call `pick-model.sh` twice, doubles the probe cost of every dead provider in the list. One call returning `base<TAB>model` avoids both. `--print-backend` is left exactly as it is.

**D3 — Ollama's OpenAI endpoint ignores thinking suppression, so the spec's Decision 1 has a measured cost.** Probed directly against `qwen3.6:35b-a3b-q8_0` on 2026-08-17:

| endpoint | suppression field | reasoning emitted |
| --- | --- | --- |
| Ollama `/api/generate` | `think: false` | 0 chars |
| Ollama `/v1/chat/completions` | `chat_template_kwargs.enable_thinking: false` | 692 chars |
| Ollama `/v1/chat/completions` | top-level `think: false` | 692 chars |
| MLX `/v1/chat/completions` | `chat_template_kwargs.enable_thinking: false` | none; 2 completion tokens total |
| Docker `/engines/v1/chat/completions` | `chat_template_kwargs.enable_thinking: false` | `reasoning_content` empty |

Deleting the Ollama-native branch therefore costs real thinking suppression on Ollama alone, and it is not recoverable through any documented OpenAI-shaped field. At `max_tokens: 16` the same call returned empty content with `finish_reason: "length"`, which is the spec's empty-output hole firing for real rather than hypothetically. Two consequences: the empty-output guard is mandatory rather than optional in the follow-up, and Ollama's position as the last entry in the default provider order is now load-bearing rather than incidental. This plan keeps the Ollama-native branch intact, so the cost is not yet incurred.

---

### Task 1: Provider-list resolution in pick-model.sh

**Files:**
- Modify: `scripts/pick-model.sh` — header env block (after the `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT` line at `:27`), and a new resolution branch before the existing `backend_requested` case at `:112`
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the environment variable `DELEGATE_BASE_URL` (space-separated ordered list of base URLs, unset by default), the shell function `resolve_via_providers()` (takes no arguments, reads the `prefs` array from scope as the file's other helpers do, prints `<base_url><TAB><model_id>` on success, returns 1 when no provider yields a match), `DELEGATE_PROBE_TIMEOUT` (integer seconds, default 1), and the flag `--print-resolution` which prints `<base_url><TAB><model_id>` for a given tier. Task 2 consumes `--print-resolution`. `--print-backend` and `--print-installed` keep their current tier-independent behaviour untouched, because `scripts/audit-models.sh` depends on it.

- [ ] **Step 1: Write the failing tests**

`tests/run-tests.sh` drives `pick-model.sh` through a `run()` helper that injects `DELEGATE_BACKEND=ollama` (`:76`) and executes under `env -i` with a mock `ollama` binary. The new path needs a mock `curl` instead. Read `run()` and `make_mock_ollama` in that file first and copy their shape rather than the sketch below, which shows intent only.

Add a mock that serves a canned `/models` body per port, so fallthrough can be exercised deterministically:

```bash
make_mock_provider() {
  # Mock curl answering GET {base}/models with an OpenAI models list. $2 is a
  # space-separated "port:id,id,id" spec; a port absent from the spec exits 7
  # (connection refused) so a test can simulate a dead provider without
  # binding a socket.
  local dir="$1" spec="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
port=\$(printf '%s' "\$url" | sed -n 's|.*://[^:/]*:\([0-9]*\).*|\1|p')
for entry in ${spec}; do
  p="\${entry%%:*}"; ids="\${entry#*:}"
  if [[ "\$p" == "\$port" ]]; then
    printf '{"object":"list","data":['
    first=1
    IFS=, read -ra arr <<< "\$ids"
    for id in "\${arr[@]}"; do
      if (( first == 0 )); then printf ','; fi
      printf '{"id":"%s","object":"model"}' "\$id"
      first=0
    done
    printf ']}'
    exit 0
  fi
done
exit 7
EOF
  chmod +x "$dir/curl"
}
```

Then add these cases. Match the surrounding label style in `run-tests.sh` (it uses `=== section ===` headings and a `check` helper; read `:130-180` and copy it rather than inventing one):

```bash
# Provider list: first reachable provider holding a tier match wins.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-community/Qwen3.6-35B-A3B-8bit 11434:qwen3.6:35b-a3b-q8_0"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:8080/v1 http://localhost:11434/v1" \
  bash "$PICK" prose)
check "provider list: first provider wins" "mlx-community/Qwen3.6-35B-A3B-8bit" "$got"

# Fallthrough: first provider unreachable (port absent from the spec -> exit 7).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:qwen3.6:35b-a3b-q8_0"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:11434/v1" \
  bash "$PICK" prose)
check "provider list: falls through an unreachable provider" "qwen3.6:35b-a3b-q8_0" "$got"

# Fallthrough: first provider reachable but holds no tier match.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:nomic-embed-text 11434:qwen3.6:35b-a3b-q8_0"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:8080/v1 http://localhost:11434/v1" \
  bash "$PICK" prose)
check "provider list: falls through a provider with no match" "qwen3.6:35b-a3b-q8_0" "$got"

# All providers unreachable -> exit 1, no model on stdout.
tmp=$(mktemp -d)
make_mock_provider "$tmp" ""
EC=0
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:8/v1" \
  bash "$PICK" prose 2>/dev/null) || EC=$?
check "provider list: all unreachable exits 1" "1" "$EC"

# A probe failure must not abort resolution under set -e.
# (Covered by the fallthrough cases above; this asserts the trace explicitly.)
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:qwen3.6:35b-a3b-q8_0"
trace=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:11434/v1" \
  bash "$PICK" --dry-run prose 2>&1)
case "$trace" in
  *"localhost:9"*) check "provider list: trace names the skipped provider" "yes" "yes" ;;
  *) check "provider list: trace names the skipped provider" "yes" "no" ;;
esac

# Sorted model output makes a two-match preference deterministic.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:qwen3.6-b,qwen3.6-a"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:8080/v1" \
  bash "$PICK" prose)
check "provider list: sorted ids make two matches deterministic" "qwen3.6-a" "$got"

# --print-resolution returns base and model in one call.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-community/Qwen3.6-35B-A3B-8bit"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:8080/v1" \
  bash "$PICK" --print-resolution prose)
check "provider list: --print-resolution returns base and model" \
  "http://localhost:8080/v1	mlx-community/Qwen3.6-35B-A3B-8bit" "$got"

# A URL carrying userinfo is rejected before any request is made.
tmp=$(mktemp -d)
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
echo "MOCK CURL WAS CALLED" >&2
exit 0
EOF
chmod +x "$tmp/curl"
EC=0
err=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://user:pass@localhost:8080/v1" \
  bash "$PICK" prose 2>&1) || EC=$?
check "provider list: userinfo URL exits 2" "2" "$EC"
case "$err" in
  *"MOCK CURL WAS CALLED"*) check "provider list: userinfo rejected before any request" "yes" "no" ;;
  *) check "provider list: userinfo rejected before any request" "yes" "yes" ;;
esac
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-tests.sh 2>&1 | grep -i fail`

Expected: the eight new checks fail (`DELEGATE_BASE_URL` is not read, so `pick-model.sh` falls through to its `auto` probe and resolves from the real host). The 110 pre-existing checks still pass. If a pre-existing check fails, stop: the new mock has leaked onto a shared PATH.

- [ ] **Step 3: Document the two new environment variables**

Insert after the `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT` line at `:27`, matching the surrounding header prose style (this file uses flowing `#` prose, not the aligned two-column form `delegate.sh` uses — copy the neighbouring lines):

```bash
#   DELEGATE_BASE_URL is a space-separated, ordered list of OpenAI-compatible
#             base URLs. When set it replaces backend probing entirely: each is
#             tried in order, and the first that answers GET {base}/models AND
#             holds a model matching the tier wins. Unset (the default) leaves
#             the DELEGATE_BACKEND path below untouched. A URL containing
#             userinfo (user:pass@) is rejected with exit 2 — it would
#             otherwise reach the metrics label and the --dry-run trace.
#   DELEGATE_PROBE_TIMEOUT bounds each /models probe. Default 1 second. Kept
#             low deliberately: a dead provider must cost roughly nothing,
#             because the whole point of the list is cheap fallthrough.
```

- [ ] **Step 4: Add the resolution function**

Insert immediately before `backend_requested="${DELEGATE_BACKEND:-auto}"` at `:112`:

```bash
# Provider-list resolution. Prints "<base_url><TAB><model_id>" for the first
# provider that is reachable AND holds a model matching the tier, or returns 1
# if none does. Provider-major rather than preference-major: the preference
# lists interleave per-provider spellings of one model (see the note at :32),
# so they are not capability rankings and letting them drive the outer loop
# silently re-routes tiers across runtimes at different quantisations.
resolve_via_providers() {
  # No arguments: reads the `prefs` array from scope, matching how the rest of
  # this file passes tier state around. `prefs` is an array (see "${prefs[@]}"
  # at the matcher below), not a space-separated string.
  local base models pref hit
  for base in $DELEGATE_BASE_URL; do
    base="${base%/}"
    # Explicit failure branch, not a bare assignment: under `set -e` a stopped
    # first provider would abort resolution before the rest were tried.
    if ! models=$(curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" \
        "$base/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | sort); then
      trace "provider $base: unreachable, skipping"
      continue
    fi
    if [[ -z "$models" ]]; then
      trace "provider $base: reachable but reports no models, skipping"
      continue
    fi
    for pref in "${prefs[@]}"; do
      # grep -im1 -F: case-insensitive so one prefs list serves every
      # provider's spelling; -F because prefs contain dots and colons that
      # would otherwise be regex metacharacters.
      if hit=$(printf '%s\n' "$models" | grep -im1 -F "$pref"); then
        trace "provider $base: matched pref '$pref' -> $hit"
        printf '%s\t%s\n' "$base" "$hit"
        return 0
      fi
    done
    trace "provider $base: no model matches this tier, skipping"
  done
  return 1
}
```

`sort` is not cosmetic: `grep -im1` takes the first match and daemon ordering is not stable, so without it a two-match preference resolves non-deterministically. `ollama list` is recency-ordered today, so this fixes a latent bug rather than introducing a constraint.

- [ ] **Step 5: Add the userinfo guard and the dispatch branch**

Immediately after the function, still before `backend_requested=`:

```bash
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  for _u in $DELEGATE_BASE_URL; do
    # Reject before any request: a userinfo URL would otherwise reach the
    # metrics label and the --dry-run trace, leaking the credential into a
    # file and onto a terminal.
    case "$_u" in
      *"://"*"@"*)
        echo "pick-model: DELEGATE_BASE_URL entry '$_u' contains userinfo (user:pass@); refusing" >&2
        exit 2
        ;;
    esac
  done
fi
```

The existing `backend_requested` case and everything below it are untouched. The provider path is wired in at the resolution site in the next step.

- [ ] **Step 6: Route resolution through the provider list when it is set**

`list_installed` is consulted at `:238` (`installed=$(list_installed)`). Read `:230-250` and add the provider branch above it so the provider list short-circuits the installed-set path entirely:

```bash
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  if ! _resolved=$(resolve_via_providers); then
    echo "pick-model: no provider in DELEGATE_BASE_URL holds a model for tier '$tier'" >&2
    echo "            tried: $DELEGATE_BASE_URL" >&2
    exit 1
  fi
  if (( print_resolution )); then
    printf '%s\n' "$_resolved"
  else
    printf '%s\n' "${_resolved#*	}"
  fi
  exit 0
fi
if (( print_resolution )); then
  echo "pick-model: --print-resolution requires DELEGATE_BASE_URL" >&2
  exit 2
fi
```

The literal tab inside `${_resolved#*	}` must be a real tab character, not `\t`. Confirm the surrounding variable names (`prefs`, `tier`) against `:228-250` before writing this.

`--print-resolution` also needs its flag registered alongside `--print-backend` at `:71-72` and a `print_resolution=0` initialiser alongside `:65-66`. It is deliberately *not* answered early with the other two backend surfaces at `:168-176`: it is tier-dependent, so it must run after the tier is parsed at `:177`, which is exactly why it exists (see D4).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/run-tests.sh 2>&1 | tail -3`
Expected: `118/118 passed` (110 existing plus the eight new checks).

- [ ] **Step 8: Commit**

```bash
git add scripts/pick-model.sh tests/run-tests.sh
git commit -m "feat(pick-model): resolve models through a provider list

DELEGATE_BASE_URL holds an ordered list of OpenAI-compatible base URLs;
the first that answers GET {base}/models and holds a tier match wins.
Provider-major with fallthrough, so an unreachable or model-less
provider is skipped rather than aborting resolution as today.

Unset by default, so the existing DELEGATE_BACKEND path is unchanged.

Refs: #363"
```

---

### Task 2: Dispatch to a resolved base URL in delegate.sh

**Files:**
- Modify: `scripts/delegate.sh` — header env block (after the `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT` entry at `:50`), the backend resolution at `:400-415`, and the MLX arm of `dispatch_to_model()`
- Test: `tests/test-delegate.sh`

**Interfaces:**
- Consumes: `DELEGATE_BASE_URL` and `pick-model.sh --print-backend` from Task 1.
- Produces: the shell variable `resolved_base` in `delegate.sh`, used by `dispatch_to_model()` in place of `$mlx_host/v1`.

- [ ] **Step 1: Write the failing test**

`tests/test-delegate.sh` already has `make_mock_curl_mlx_ok "$dir" "$payload_sniff" "$argv_sniff"` (`:764-799`), which answers `/v1/models` with `{"object":"list","data":[]}` and records argv. An empty `data` array is no longer adequate once discovery is real, so add a variant that returns a populated list. Insert after `make_mock_curl_mlx_ok` ends at `:799`:

```bash
make_mock_curl_provider() {
  # Mock curl for the provider path: answers {base}/models with a populated
  # OpenAI list so tier resolution succeeds, records dispatch argv to $3, and
  # returns a chat-completions body. Unlike make_mock_curl_mlx_ok, the models
  # response is non-empty, because under DELEGATE_BASE_URL the /models call IS
  # discovery rather than a liveness probe.
  local dir="$1" payload_sniff="${2:-/dev/null}" argv_sniff="${3:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"/models"*)
      cat > /dev/null
      printf '%s' '{"object":"list","data":[{"id":"qwen3.6-test","object":"model"}]}'
      exit 0
      ;;
  esac
done
printf '%s\n' "\$*" > "${argv_sniff}"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${payload_sniff}"
body='{"choices":[{"message":{"role":"assistant","content":"provider-output-ok"},"finish_reason":"stop"}]}'
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

Append these cases before the final tally:

```bash
# 38. DELEGATE_BASE_URL dispatches to {base}/chat/completions on the resolved
# provider, with no MLX_HOST or OLLAMA_HOST involvement.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "provider dispatch exits 0"
assert_contains "provider-output-ok" "$out" "provider dispatch parses .choices[0].message.content"
argv=$(cat "$argv_sniff")
assert_contains "http://localhost:12434/engines/v1/chat/completions" "$argv" "provider dispatch posts to {base}/chat/completions"
rm -rf "$tmp" "$metrics"

# 39. The resolved base URL is bounded by DELEGATE_REQUEST_TIMEOUT like every
# other dispatch (regression guard for the PR 1 work).
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff")
assert_contains "--max-time 600" "$argv" "provider dispatch keeps the 600s bound"
rm -rf "$tmp"

# 40. A trailing slash on the base URL does not produce a doubled slash.
tmp=$(mktemp -d)
argv_sniff="$tmp/argv.txt"
make_mock_curl_provider "$tmp" "$tmp/payload.json" "$argv_sniff"
env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  DELEGATE_BASE_URL="http://localhost:12434/engines/v1/" \
  bash "$SCRIPT" prose "Summarise" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$argv_sniff")
assert_contains "engines/v1/chat/completions" "$argv" "trailing slash is stripped once"
rm -rf "$tmp"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-delegate.sh 2>&1 | grep FAIL`
Expected: the six new assertions fail. The 562 pre-existing assertions still pass.

- [ ] **Step 3: Document the variable**

Insert after the `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT` entry at `:50`, matching the aligned two-column form (`delegate.sh`'s continuation `#` sits at column 45 — measure a neighbouring line rather than copying this block's spacing):

```bash
#   DELEGATE_BASE_URL=<urls>                # space-separated ordered list of
#                                           #   OpenAI-compatible base URLs.
#                                           #   When set it replaces
#                                           #   DELEGATE_BACKEND entirely:
#                                           #   resolution walks the list and
#                                           #   dispatch posts to
#                                           #   {base}/chat/completions. Unset
#                                           #   by default.
```

- [ ] **Step 4: Resolve the base URL**

The backend case sits at `:400-412` and the hosts at `:414-415`. Add the provider branch above it, leaving the existing case intact for the unset path:

Resolution cannot happen at `:400` because `delegate.sh` does not fetch the model until `:926` (`model=$(bash "$pick" "$tier" 2>"$pick_err")`). Set only the backend label at `:400`:

```bash
resolved_base=""
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  backend="provider"
fi
```

and replace the single resolution call at `:926` so one invocation yields both halves, rather than probing the list twice:

```bash
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  # One call, not two: --print-resolution returns "<base>\t<model>" so a dead
  # provider is probed once rather than once per question.
  if _resolved=$(bash "$pick" --print-resolution "$tier" 2>"$pick_err"); then
    resolved_base="${_resolved%%	*}"
    model="${_resolved#*	}"
  else
    model=""
  fi
else
  model=$(bash "$pick" "$tier" 2>"$pick_err")
fi
```

Both `%%` and `#` expansions need a literal tab. Read `:920-940` first: the existing failure handling around `$pick_err` must keep working for both branches, so the `if`/`else` above has to preserve whatever exit-status check follows the original line.

- [ ] **Step 5: Dispatch to the resolved base**

In `dispatch_to_model()`, the MLX arm posts to `"$mlx_host/v1/chat/completions"`. Make the destination a variable so the OpenAI arm serves both, changing only the URL expression:

```bash
  chat_url="${resolved_base:-$mlx_host/v1}/chat/completions"
```

and use `"$chat_url"` in the curl. `resolved_base` already has one trailing slash stripped by Task 1 Step 4 (`base="${base%/}"`), so no doubled slash is possible. The payload, the `--max-time`/`--connect-timeout` flags from PR 1, and the `.choices[0].message.content` parse are all unchanged: this is the point of the design, that the MLX arm was already the generic OpenAI arm.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test-delegate.sh 2>&1 | tail -3`
Expected: `568 passed, 0 failed` (562 existing plus the six new assertions).

- [ ] **Step 7: Run the full suite**

```bash
bash tests/test-delegate.sh 2>&1 | tail -2                 # 568
bash tests/run-tests.sh 2>&1 | tail -2                     # 118
bash tests/test-embed.sh 2>&1 | tail -2                    # 51 unchanged
bash tests/test-delegate-feedback.sh 2>&1 | tail -2        # 226 unchanged
bash tests/test-delegate-boundary-hook.sh 2>&1 | tail -2   # 134 unchanged
bash tests/test-prompts-library.sh 2>&1 | tail -2          # 288 unchanged
bash tests/test-metrics-summary.sh 2>&1 | tail -2          # 135 unchanged
bash tests/test-sync-metrics-to-loki.sh 2>&1 | tail -2     # 30 unchanged
```

Any change to the five "unchanged" counts means the additive guarantee has been broken. Stop and fix rather than updating the expected number.

- [ ] **Step 8: Verify the goal against the real daemons**

This is the plan's stated verifiable goal. With MLX on `:8080`, Docker Model Runner on `:12434` and Ollama on `:11434`:

```bash
DELEGATE_BASE_URL="http://localhost:12434/engines/v1" bash scripts/delegate.sh prose "Say the single word: ok"
```
Expected: `ok`, and the `delegate-meta` line names a `docker.io/ai/...` model.

```bash
DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:8080/v1" bash scripts/pick-model.sh --dry-run prose
```
Expected: resolves the MLX model; the trace contains `provider http://localhost:9/v1: unreachable, skipping`.

```bash
DELEGATE_BASE_URL="http://user:pass@localhost:8080/v1" bash scripts/pick-model.sh prose; echo "exit=$?"
```
Expected: `exit=2`, stderr names userinfo.

```bash
bash scripts/delegate.sh prose "Say the single word: ok"
```
Expected: unchanged behaviour with `DELEGATE_BASE_URL` unset.

- [ ] **Step 9: Commit**

```bash
git add scripts/delegate.sh tests/test-delegate.sh
git commit -m "feat(delegate): dispatch to a DELEGATE_BASE_URL provider

When DELEGATE_BASE_URL is set, pick-model.sh resolves which provider
holds the tier's model and delegate.sh posts to {base}/chat/completions.
The MLX arm was already the generic OpenAI arm, so this parameterises
its destination rather than adding a branch: Docker Model Runner works
with no Docker-specific code.

DELEGATE_BACKEND is untouched and remains the default path.

Refs: #363"
```

---

## Out of Scope

Named explicitly so an executor does not drift into the follow-up:

- Removing `DELEGATE_BACKEND`, `OLLAMA_HOST`, `MLX_HOST` and the `/api/generate` dispatch branch. See D1: 76 references and 162 mock call sites, and D3 means the deletion has a measured cost that deserves its own decision.
- The empty-output guard. It belongs with the `/api/generate` deletion, because D3 shows that deletion is what makes the hole reachable.
- The `audit-models.sh` rework and the `embed.sh:182` conversion (D2). Both are consequences of removing `DELEGATE_BACKEND`.
- Renaming `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT`. `DELEGATE_PROBE_TIMEOUT` is introduced here as the name for the *new* probe; unifying the two names is part of the removal PR.
- `eval-skill-triggers.sh`, `SKILL.md`, README, dashboards and ADRs. All PR 3.
