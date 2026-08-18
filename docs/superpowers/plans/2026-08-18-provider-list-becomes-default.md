# Provider list becomes the default — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OpenAI-compatible provider list the resolution path for every dispatch, in two stages that can each be verified on their own.

**Spec:** `docs/superpowers/specs/2026-08-18-backlog-completion-design.md` (task T5)

**Status:** rewritten 2026-08-18 after two review agents measured the first draft against a patched copy of the repo. The first draft was wrong about the size of the work, wrong about where the seam is, and contained an acceptance test that passed while the feature it tested was broken. Those findings are kept in "What the first draft got wrong", because they are the reason for the shape below.

## Global Constraints

- bash 3.2: no associative arrays, no `${var^^}`, no `mapfile`, no `grep -P`. Verified: every snippet here runs under `/bin/bash` 3.2.57.
- `pick-model.sh` runs under `set -euo pipefail`; `delegate.sh` under `set -uo pipefail`.
- Conventional Commits, one branch per stage.
- Do not reformat or reorder unrelated lines.

## Measured baselines (2026-08-18, all three daemons live)

| suite | in CI | baseline |
|---|---|---|
| `tests/run-tests.sh` | yes | 123/123 |
| `tests/test-delegate.sh` | yes | 601 passed, 0 failed |
| `tests/test-embed.sh` | yes | 51 passed, 0 failed |
| `tests/test-semantic-search.sh` | yes | 29 passed, 0 failed |
| `tests/test-metrics-summary.sh` | yes | 135 passed, 0 failed |
| `tests/test-delegate-feedback.sh` | yes | 226 passed, 0 failed |
| `tests/test-eval-skill-triggers.sh` | yes | 65 passed, 0 failed |
| `tests/test-onboard.sh` | yes | 37 passed, 0 failed |
| `tests/test-delegate-boundary-hook.sh` | yes | 134 passed, 0 failed |
| `tests/test-backfill-otel.sh` | yes | 58 passed, 0 failed |
| `tests/test-observability-doctor.sh` | yes | 22 passed, 0 failed |
| `tests/test-dashboards.sh` | yes | 35 passed, 0 failed |
| `tests/test-prompts-library.sh` | yes | 288 passed, 0 failed |
| `tests/test-sync-metrics-to-loki.sh` | yes | 30 passed, 0 failed |
| `tests/test-project-name.sh` | yes | 7 passed, 0 failed |
| `tests/test-validate-content.sh` | yes | 32 passed, 0 failed |
| `tests/test-validate-frontmatter.sh` | yes | 10 passed, 0 failed |

`run-tests.sh` results flip in **both** directions depending on whether daemons are
reachable: "missing ollama -> exit 1", "empty ollama list -> exit 1" and "no match ->
exit 1" pass only when nothing is reachable, while "code tier exits 0" and "dry-run
match -> exit 0" pass only when something is. A green local run is not evidence for
CI, and vice versa. Validate stage 2 under both conditions.

---

## Stage 1: make the provider mode explicit

**Goal:** every site that asks "are we in provider mode?" asks `$backend`, not "is
`DELEGATE_BASE_URL` non-empty?". **No behaviour changes at all.**

This is the whole reason the first draft failed. Six sites use "the variable is set"
as a proxy for "the user chose the provider path":

```
scripts/pick-model.sh:115   userinfo validation
scripts/pick-model.sh:182   backend label
scripts/pick-model.sh:210   list_installed provider arm
scripts/pick-model.sh:331   resolve_via_providers
scripts/delegate.sh:443     backend label
scripts/delegate.sh:973     --print-resolution call site
```

Today the proxy is exact, because `backend` is set to `provider` at `pick-model.sh:182`
if and only if `DELEGATE_BASE_URL` is non-empty. The moment stage 2 gives the variable
a default, the proxy inverts silently: every gate becomes unconditionally true, and
`DELEGATE_BACKEND=ollama` sets a label that `--print-backend` reports and metrics
record while resolution still walks the provider list.

A review agent measured exactly that against the first draft's code:

```
$ DELEGATE_BACKEND=ollama pick-model.sh --print-backend
ollama                                    # the first draft's acceptance test PASSED
$ DELEGATE_BACKEND=ollama pick-model.sh --dry-run prose
dry-run: provider http://localhost:8080/v1: matched preference='qwen3.6'
```

Doing this refactor first, on its own, with the default still unset, means the change
is provable by *absence of change*: every suite must hold its exact baseline.

- [ ] **Step 1: Change the gates at `pick-model.sh:210` and `:331`**

Replace `if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then` with
`if [[ "$backend" == "provider" ]]; then` at both sites. Leave `:115` alone: it is
input validation on the variable itself, not a mode question, and it must run whenever
a value is present. Leave `:182` alone: it is what *assigns* the mode.

- [ ] **Step 2: Change the gates at `delegate.sh:443` and `:973`**

Same substitution. `delegate.sh:443` currently runs its own copy of the precedence
logic; it must end up asking `pick-model.sh` rather than deciding independently,
otherwise stage 2 produces split-brain resolution where `delegate.sh` probes into one
daemon and `pick-model.sh` returns a model id belonging to another. A review agent
reproduced that as a live 404:

```
$ printf '...' | MLX_HOST=http://localhost:18080 bash scripts/delegate.sh prose "..."
rc=22  curl: (22) The requested URL returned error: 404
```

- [ ] **Step 3: Update the comments that describe the old contract**

`pick-model.sh:180-181` says "DELEGATE_BASE_URL supersedes backend probing entirely".
`pick-model.sh:206-209` and `:329-330` describe the gate as conditional on the list
being set. `delegate.sh:148-151` says "When set it supersedes DELEGATE_BACKEND". All
four become wrong in stage 2 and misleading now.

- [ ] **Step 4: Verify by absence of change**

Run every suite in the baseline table. **Every count must be identical.** A single
changed number means the refactor was not behaviour-preserving, and the cause must be
found before proceeding rather than absorbed by editing an assertion.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: gate provider resolution on the resolved backend, not on DELEGATE_BASE_URL"
```

---

## Stage 2: flip the default, and remove the native path in the same PR

**Goal:** `DELEGATE_BASE_URL` defaults to the three-provider list, and the
`/api/generate` arm plus `DELEGATE_BACKEND` are gone.

**Why these are one PR and not two.** The first draft split them so that "a suite
failure in the deletion is unambiguously a missed reference". Measurement killed that
reasoning. Flipping the default moves roughly 50 ollama-shaped tests onto the OpenAI
arm, where the request envelope (`{prompt, options.temperature}` becomes
`{messages, max_tokens}`), the URL (`/api/generate` becomes `/chat/completions`) and
the response parser (`.response` becomes `.choices[0].message.content`) all change.
Those tests then need migrating. Deleting the native arm afterwards deletes most of
that same work. Splitting migrates every one of them twice, and the intermediate state
is not a state anyone should ship.

**Honest size.** The first draft claimed the mock work was "four helper functions, not
159 call sites". Both halves were wrong.

`tests/test-delegate.sh` defines **nine** curl-mock helpers (lines 43, 90, 106, 140,
756, 1527, 2902, 5054, plus `make_mock_ollama` at 26) and **eight** tests write a curl
mock inline, bypassing every helper (942, 1741, 1822, 1892, 3176, 3934, 4003, 5041).
Twelve further tests write an inline `ollama` mock (270, 1049, 1195, 1487, 2096, 2335,
3255, 3706, 4077, 4383, 4401, 4918). That is 17 mock definitions to change, not 4.

The "roughly 34 tests with no curl mock" figure was off by a factor of thirty. Of the
113 blocks calling `make_mock_ollama`, **112 install a curl mock immediately after**;
exactly one does not (line 4894, `unknown tier -> exit 2`, which never reaches
dispatch). The corollary matters more than the number: because 112 of 113 blocks
overwrite whatever `make_mock_ollama` writes, adding a curl mock there would be almost
entirely inert. The genuinely uncovered blocks are the 12 inline-ollama ones, of which
line 4917 is the concrete example, asserting "valid but unresolvable tier -> exit 1"
and returning 0 on a machine with live daemons.

Applying the first draft's mock steps as written measured **420 passed, 173 failed**.
Patching the eight remaining probe arms reached 492/101. After every mechanical fix a
reviewer could apply, **56 failures remained** that are genuine per-call-site
migrations, clustered in `payload:`, `checks:` (16), `strip-think` (7), the Ollama
canary tests (4), `QS1/QS2/QS6` and `OT2/OT3/OT4/OT15`.

- [ ] **Step 1: Rewrite the assertions that the design contradicts**

These cannot be fixed by re-mocking; they assert behaviour that ceases to exist.

```
tests/run-tests.sh:982        --print-resolution without DELEGATE_BASE_URL exits 2
tests/run-tests.sh:620        --print-backend resolves auto through the MLX probe
tests/run-tests.sh:424        assert_contains "unknown backend"
tests/run-tests.sh:536-538    auto + curl-ok
tests/run-tests.sh:550-552    auto + curl-fail
tests/run-tests.sh:564-565    default (unset) backend
tests/run-tests.sh:103,352,639,430-432   bare-SAFE_PATH "ollama not on PATH" / "MLX hub cache not found"
tests/test-delegate.sh:911    12g
tests/test-delegate.sh:930-931 12h
tests/test-delegate.sh:952    12i DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT
```

- [ ] **Step 2: Build the default list from the host variables, not literals**

Three hardcoded ports would make `MLX_HOST` and `OLLAMA_HOST` dead, silently
re-routing anyone running Ollama on a non-default port or a remote host back to
localhost. Measured on the first draft:

```
OLLAMA_HOST=http://localhost:11435 DELEGATE_BACKEND=ollama pick-model.sh --dry-run prose
  today:   "no models installed (backend=ollama)", exit 1   (correct)
  patched: mlx-community/Qwen3.6-35B-A3B-8bit               (silently wrong host)
```

Use `${MLX_HOST:-http://localhost:8080}/v1`,
`${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1`,
`${OLLAMA_HOST:-http://localhost:11434}/v1`. Order is provider-major and deliberate:
ADR 0022 measured MLX at roughly an order of magnitude lower latency on identical
weights.

- [ ] **Step 3: Fix `run-tests.sh`'s `make_mock_ollama` to serve its own model list**

The `run()` pin at `tests/run-tests.sh:76` cannot simply be dropped: doing so measured
76/123. `run-tests.sh` has its own `make_mock_ollama` at `:44` that takes the model
list as `$2`, and about 20 tests pass bespoke lists (`:114`, `:124`, `:132`, and the
vision, embedding, premium-general, reasoning-vision and override cases). A fixed
provider body breaks every one. The mock must emit a `curl` shim serving **the same
`$2` list** as `{"data":[{"id":…}]}`.

- [ ] **Step 4: Give `test-semantic-search.sh`'s mock a models arm**

Not named in the first draft, and it runs in CI. `semantic-search.sh:69` shells out to
`embed.sh`, and `make_mock_curl_deterministic` (`tests/test-semantic-search.sh:62`)
only understands `POST /api/embed`. A `GET /v1/models` gets the embeddings body, no
ids are found, and the suite drops **29 to 8**. Add a `*/models)` arm returning
`{"data":[{"id":"nomic-embed-text:latest"}]}`, and give it an early `exit 0` before
the unconditional `payload=$(cat)`, which otherwise hangs on a stdin-less probe.

- [ ] **Step 5: Fix `audit-models.sh`**

`audit-models.sh:22-25` takes `--print-backend`, gets `provider`, and re-exports it as
`DELEGATE_BACKEND=provider`, which the backend `case` rejects with exit 2 under
`set -euo pipefail`. Measured: the script dies after printing its first heading, where
today it prints a full inventory and the eight-tier routing table.

- [ ] **Step 6: Make "nothing reachable" say so**

With all providers down, `resolve_via_providers` cannot distinguish "nothing
reachable" from "reachable but no matching model", so both collapse to "no provider
holds a model for tier 'prose'", and `delegate.sh` wraps that in advice to run
`audit-models.sh`. Both statements are false on a machine with no daemon running.
Count reachable providers and, when the count is zero, say so.

- [ ] **Step 7: Migrate the 56 remaining per-call-site assertions**

- [ ] **Step 8: Verify under both conditions**

Run every suite with daemons live, then again with the default list pointed at three
dead ports. State both sets of counts in the PR with a reason for every change.

---

## Not doing: the Task 4 hermeticity sniff, as first written

The first draft added a sniffing `curl` shim to `SAFE_PATH` in `run-tests.sh`. The
mechanism works (verified: a test with a mock gets the mock, a test without one gets
`rc=99` and a sniff line). It is in the wrong place, and it would fire on legitimate
tests.

Nine test files define their own `SAFE_PATH`, and the draft patched only
`run-tests.sh`, while the uncovered blocks are in `test-delegate.sh`.
`run-tests.sh:92, 97, 101, 187, 192, 350, 385, 637` deliberately run on bare
`$SAFE_PATH` with no mock, so each would be a false positive. And the draft's own
verification step said to prove the guard by deleting a mock from `test-delegate.sh`
while the guard lives in `run-tests.sh`, which has a separate `make_mock_ollama`.

The underlying concern is real and measured: with only a mock `ollama` on PATH,
`pick-model.sh --dry-run prose` reached the live MLX daemon in 43 ms and resolved a
model that *satisfies* the assertion under test. But the right fix is narrow, because
the exposure is narrow: 12 inline-ollama blocks, listed in stage 2. Fix those
directly and revisit a general guard afterwards.

## Known hazard, unrelated to this change

Docker Model Runner lists `docker.io/ai/qwen3.6:35b-mlx`, and every chat request to it
returns HTTP 400, "default chat template is no longer allowed". The other two Docker
models answer normally. Resolution is capability-blind, so if a tier's preference list
matches that model, dispatch 400s. Recorded so it is not mistaken for a regression
introduced here.

## What the first draft got wrong

Kept deliberately: each item is a mistake worth not repeating.

**The acceptance test certified a broken feature.** Task 1's test asserted
`DELEGATE_BACKEND=ollama --print-backend` prints `ollama`. It does, while resolution
still walks the provider list. A test that asserts the one string still updated
correctly is worse than no test.

**The seam was assumed, not measured.** "Four functions, not 159 call sites" came from
reading `make_mock_curl_ok`'s comment. Counting found 17 mock definitions and 12
inline ollama mocks.

**The "34 unmocked tests" figure was arithmetic, not observation.** 113 minus 79
assumed one curl mock per helper call; the real per-helper tally is 72/18/16/13/8/5/2/2
plus 8 inline, 144 in total. The true count of blocks with no curl mock is one.

**The line range was wrong.** Replacing `pick-model.sh:182-186` leaves the `case…esac`
at 187-196 and the `fi` at 197 orphaned: `syntax error near unexpected token 'fi'`.
The block is 182-197.

**Two suites were never listed.** `test-embed.sh` (drops to 25/26 without the stage 1
fix) and `test-semantic-search.sh` (drops to 8/21), both in CI.

**The empty-output guard's sentinel was wrong**, and is already fixed. Setting
`status=1` tripped the generic dispatch-failure block into printing
`dispatch failed (curl exit 1)` and advising a daemon restart, which is the wrong
diagnosis and a real curl code. Shipped in #370 as `EMPTY_RESPONSE_STATUS=100`, above
curl's range, with a test asserting the transport advice is not printed.
