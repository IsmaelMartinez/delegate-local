# Provider-agnostic backend: one OpenAI-compatible driver

Date: 2026-08-17

## Status

Approved in principle. Revised twice: a four-reviewer pass on the first draft,
then a three-reviewer critical pass on the second. The second pass reversed two
decisions the first pass had introduced, so the history is recorded under
"Reversals" below rather than quietly dropped.

Supersedes the two-backend model in ADR 0022, whose performance rationale for
preferring MLX not only stands but is now load-bearing (see Decision 3).

## Context

`delegate.sh` and `pick-model.sh` hardcode two backends: Ollama at
`POST /api/generate` with a `think` field and nested `options`, MLX at
`POST /v1/chat/completions` in the OpenAI shape. Discovery is equally forked —
`ollama list` parsed with awk, versus a filesystem scan of `$HF_HOME/hub`.

Device policy on the primary workstation blocked `huggingface.co` at the socket
layer in August 2026, and Ollama is expected to be blocked by the same policy.
Docker Model Runner is reachable, serves an OpenAI-compatible API at
`http://localhost:12434/engines/v1`, mirrors `mlx-community` weights as OCI
artifacts (the `ai/qwen3.6:35b-mlx` manifest carries
`ai.model.repo=mlx-community/Qwen3.6-35B-A3B-nvfp4`), and benchmarked at
92.1 tok/s wall-clock against Ollama's 83.8 on bit-identical
`qwen3.6:35b-a3b-q8_0` weights. Adding it as a third hardcoded backend would
mean three dispatch branches and three discovery branches.

All three runtimes already expose `GET /v1/models` and
`POST /v1/chat/completions`. The fork is unnecessary.

## Reversals from the previous draft

**R1 — there is no pre-existing `//` bug.** The previous draft asserted a live
defect at `delegate.sh:1243`. That line is
`jq -r '.choices[0].message.content // ""'`, where the `//` does useful work:
without it a `null` content renders as the literal string `null`. The dead-code
critique applied only to the *draft's own proposed* `content // .reasoning`
expression, never to shipped code. Verified directly. Issue #363 repeats this
error and must be corrected.

**R2 — resolution must be provider-major, not preference-major.** The previous
draft made preferences the outer loop, on the reasoning that provider order
should not beat capability order. That premise is false. The preference lists
are not capability rankings: four of the eight interleave per-provider spellings
of one model — `deepseek-r1:32b` beside `deepseek-r1-distill-qwen-32b`,
`qwen3.5:122b` beside `qwen3.5-122b`, and the same pattern in both vision lists.
This is documented at `pick-model.sh:32-33` and restated in ADR 0022: the single
list serves both backends because the matcher is case-insensitive, so "the
choice is about *where* a model runs, not *which* capability you get."

Simulated independently by two reviewers against the three live daemons,
preference-major diverges on three of eight tiers. Only `code` is a genuine
capability change. `reasoning` and `premium-general` move to Ollama for the same
logical model — `deepseek-r1:32b` is Q4_K_M against MLX's 8-bit, so the
reasoning tier would be silently *down*-quantised, and premium-general moves at
identical 4-bit quant for no gain. Since ADR 0022 measured MLX at roughly an
order of magnitude lower latency on identical weights, preference-major would
route two tiers to a far slower runtime for zero capability benefit, one of them
the tier already flagged as the latency risk.

Provider-major with fallthrough is therefore restored. It is also strictly
better than today, where `auto` picks MLX and then exits 1 rather than trying
Ollama.

## Decisions

1. **One driver.** The Ollama-native dispatch path is deleted; every provider is
   called at `POST {base}/chat/completions`.
2. **Providers are base URLs**, in one ordered list. No provider-name registry
   in the chat path.
3. **Resolution is provider-major with fallthrough.** The first provider that is
   reachable *and* holds a model matching the tier wins; otherwise try the next.
4. **`delegate.sh` owns resolution** and passes the chosen base URL down to
   `pick-model.sh`, reusing the `DELEGATE_BASE_URL=… bash "$pick" <tier>` idiom
   that already exists at `embed.sh:175`.
5. **Scope is chat generation.** `embed.sh` gets a timeout and a one-line
   provider pin; the rest is issue #362.
6. **The HuggingFace cache scan is removed.** Discovery is only ever "what a
   running provider reports" — which is a correctness gain, not just a
   simplification: the scan currently reports
   `mlx-community/Qwen3.8-27B-8bit` as installed when only part of its shards
   are present, because `has_snap` only tests that a snapshot directory is
   non-empty. `mlx_lm.server`'s `/v1/models` correctly omits it.

### What was cut, and why

`DELEGATE_API_KEY`, the non-loopback restriction, the `base_url` metrics field,
`--print-resolution`, the `--print-installed` grouping, the `config.sh` freeze,
and two of the four phases.

Loopback enforcement was cut because it is theatre: a reviewer bound a listener
on `127.0.0.1:9999` forwarding to `example.com:80`, and the check passed while
content left the machine. Any SSH `-L`, socat, or published container port
defeats it identically. It was also an unacknowledged breaking change —
`README.md:145` documents `OLLAMA_HOST`/`MLX_HOST` as endpoints with no locality
constraint, so a user pointing at a LAN box would hard-fail where `embed.sh`
works today. The real concern, credentials in a URL, is addressed directly by
rejecting URLs containing userinfo, which is cheap and actually effective.

The `config.sh` freeze became unnecessary under Decision 4: `delegate.sh`
resolves the base URL and passes it in, so `pick-model.sh` never returns a
destination and the override never gains one. Zero code, threat gone.

## Configuration surface

```sh
DELEGATE_BASE_URL          # space-separated ordered list of OpenAI-compatible
                           # base URLs. First that yields a tier match wins.
                           # Default: "http://localhost:8080/v1
                           #           http://localhost:12434/engines/v1
                           #           http://localhost:11434/v1"
                           # One trailing slash stripped per entry. A URL
                           # containing userinfo (user:pass@) is rejected,
                           # exit 2 — it would otherwise reach the metrics
                           # label and the --dry-run trace.

DELEGATE_REQUEST_TIMEOUT   # seconds for the dispatch POST. Default 600.
                           # NEW; see the evidence below.

DELEGATE_PROBE_TIMEOUT     # seconds per /models probe. Default 1, unchanged
                           # from DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT, which it
                           # renames (asserted at test-delegate.sh:943).
```

`DELEGATE_BACKEND` is removed. Pinning is a single-entry `DELEGATE_BASE_URL`.

### Why 600 seconds

Measured over 1376 successful delegate rows: p50 3,726 ms, p95 40,095 ms,
p99 80,180 ms, p99.9 232,503 ms, max 11,582,773 ms. The maximum is a 3.2-hour
`long-context` runaway producing 961,344 output chars — exactly what a timeout
should kill. The largest *genuine* call is 505,073 ms, of which 504,601 ms is
cold model load and 472 ms is generation; the third largest, 232,503 ms, has the
same shape. The binding constraint on this workstation is model load, not
generation, and `--max-time` bounds the whole request including load. 600 s
preserves every genuine call in recorded history with 19% margin while killing
the runaway. 300 s would have severed two real calls.

Paired with `--connect-timeout 5`, since connect failure and generation stall
deserve different bounds.

## pick-model.sh

Removed: `auto_resolve_backend()` (102-110), `backend_requested` and its case
(112-122), both branches of `list_installed()` (130-163), and the backend prose
in the header (20-33).

Added: an eleven-line loop that, for each base URL, curls `{base}/models` with
`--max-time $DELEGATE_PROBE_TIMEOUT`, pipes through
`jq -r '.data[].id' | sort`, and continues on failure. The `sort` matters
because `grep -im1` takes the first match and daemon ordering is not stable —
`ollama list` is already recency-ordered today, so this fixes a latent
non-determinism rather than introducing one.

The file runs under `set -euo pipefail` (line 40), so the probe must be called
with an explicit failure branch (`if ! models=$(…); then continue; fi`). As a
bare assignment, a stopped first provider would abort resolution before the
others were tried — the exact inverse of Decision 3.

Unchanged: the preference lists, the tier case, `--print-prefs`, the `config.sh`
override hook and its ownership and permission checks, and the `grep -im1 -F`
matcher. `--print-backend` keeps its name and prints the resolved base URL;
`--print-installed` keeps its one-model-per-line shape. Both are repo-internal
with a single consumer, so renaming buys nothing here.

## delegate.sh

Removed: the probe case (385-403), `ollama_host` and `mlx_host` (404-405), the
Ollama arm of the canary (1096-1104), and the entire `/api/generate` dispatch
branch (1194-1247).

Dispatch keeps the payload the MLX branch already builds — `model`, `messages`,
`stream:false`, `temperature`, `max_tokens`,
`chat_template_kwargs.enable_thinking`, plus optional `top_p` and
`presence_penalty` — posted to `{base}/chat/completions` with
`--max-time $DELEGATE_REQUEST_TIMEOUT --connect-timeout 5`.

`top_k` is dropped: it is not an OpenAI chat-completions parameter, MLX accepts
it only as an extension (`delegate.sh:1229-1231`), and a strict provider
returning 400 would make `DELEGATE_TOP_K` a hard dispatch failure. Verify per
provider before reinstating.

Recovery text at `:1118`, `:1127` and `:1276` is rewritten to name the base URL
and the list tried, replacing references to `ollama serve` / `mlx_lm.server` and
`OLLAMA_HOST` / `MLX_HOST`.

### The empty-output guard

Today an empty response is treated as complete success. Reproduced end to end
with a mock returning `{"choices":[{"message":{"content":""},"finish_reason":"length"}]}`:
exit 0, a bare newline on stdout, a `delegate-meta` line claiming success, a
metrics row with `output_chars: 0` and `exit_status: 0`, and the verdict nudge
asking the operator to grade nothing. The same holds on the Ollama branch with
`{"response":""}`.

This has never fired in recorded history — 99 rows have `output_chars: 0` and
every one already carries a non-zero exit — so it is a reachable hole rather
than an observed incident. It is still worth closing, because collapsing to one
driver makes it *more* reachable: `DELEGATE_MAX_TOKENS` (4096) applies only to
the MLX branch today (`:207`, `:1225`) and becomes universal, while Ollama
currently sets no `num_predict` at all.

The guard sets `status` to a distinct non-zero code when `status == 0` and the
output is empty, naming `DELEGATE_MAX_TOKENS` when `finish_reason == "length"`.
Two implementation traps, both found by prototyping rather than reading:
reassigning `$status` alone makes the block at `:1273-1279` fire with misleading
"check the backend daemon" advice, so the guard needs its own flag or an `elif`;
and emptiness must be tested with `[[ -z ]]`, never jq `//`, which does not
treat `""` as absent.

Keying the same guard on `finish_reason == "length"` regardless of emptiness
also catches a second live defect: with `think:false`, `deepseek-r1:32b` on
Ollama still emits its trace inline in `.response`, and when that trace is
truncated before its closing tag the strip at `:1261` finds no `</think>` and
returns raw chain-of-thought as the answer, exit 0.

### No `.reasoning` fallback

`DELEGATE_STRIP_THINK` strips on a literal `</think>` (`:1261`) and defaults on
only for the reasoning tier (`:1256-1260`). Ollama's `reasoning` field has the
delimiters already removed, so any fallback to it would return chain-of-thought
as the answer. Providers also disagree on the field name — Ollama uses
`reasoning`, Docker uses `reasoning_content` — which independently confirms the
rule. `.content` only.

## Metrics

The JSONL `backend` field keeps a short label; no `base_url` field is added.
`scripts/lib/otel.sh:260` maps `backend` to `gen_ai.provider.name` and
`dashboards/grafana/delegate-overview.json:777` does `sum by (backend)` with a
`{{backend}}` legend, so emitting URLs would split every historical series.

The label is derived from the base URL: the three known defaults map to `mlx`,
`docker` and `ollama`; anything else uses `host:port`. It must **not** fall back
to `openai`, which is a registered SemConv provider string meaning OpenAI —
labelling a local llama.cpp endpoint `openai` would be conformant-looking and
false.

`docs/otel-schema.md:70` claims "Both `ollama` and `mlx` are already registered
as provider strings in the SemConv registry". They are not; the registry enum is
anthropic, aws.bedrock, azure.ai.inference, azure.ai.openai, cohere, deepseek,
gcp.gemini, gcp.gen_ai, gcp.vertex_ai, groq, ibm.watsonx.ai, mistral_ai, openai,
perplexity, x_ai. That documentation error is corrected as part of this work
rather than preserved.

`embed.sh` keeps writing the literal `ollama` label, which stays consistent
under this scheme.

## Staging

Two shipping PRs plus docs, split on a mechanical dependency rather than nerves.

**PR 1 — unbounded curls.** Add `--max-time`/`--connect-timeout` to the dispatch
curls at `delegate.sh:1207` and `:1239`, to `embed.sh:192`, and to
`sync-metrics-to-loki.sh:178` and `:189`. Genuinely independent of everything
else and shippable immediately. The 600 s default and its evidence go in the
commit message.

**PR 2 — the collapse.** Driver collapse, base-URL resolution, the empty-output
guard, `audit-models.sh` rework, the test-mock migration, and
`eval-skill-triggers.sh` moved onto the shared driver. That last item belongs
here rather than later, because it posts to `${OLLAMA_HOST}/api/generate`
(`:182,193`) and `.github/PULL_REQUEST_TEMPLATE.md:17` mandates it as the gate
for `SKILL.md` changes — which PR 3 makes. Migrating it in PR 2 dissolves that
self-blocking dependency.

**PR 3 — docs, dashboards, ADRs.**

The empty-output guard deliberately sits in PR 2, not PR 1: `finish_reason` has
two spellings today (`.done_reason` on Ollama, `.choices[0].finish_reason` on
MLX) and `DELEGATE_MAX_TOKENS` is MLX-only, so implementing it earlier means
per-branch code and a fixture that PR 2 immediately deletes.

## Testing

The load-bearing constraint is hermeticity. `run-tests.sh:76` injects
`DELEGATE_BACKEND=ollama` into all 48 `pick-model.sh` invocations through
`run()`, and `run()` uses `env -i` with
`SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"` (`:11`) containing the real
`/usr/bin/curl`. Today the pin means zero HTTP. After the change those tests
would issue real localhost requests, passing on a developer machine for the
wrong reason and passing in CI by timing out. So `run()` swaps the pin for
`DELEGATE_BASE_URL=<mock>` and `make_mock_ollama` becomes `make_mock_provider`,
writing a mock `curl` that returns a canned `{"data":[{"id":…}]}` body. That is
a like-for-like substitution of the existing mock-binary-on-restricted-PATH
pattern; the 32 call sites change only their body literal.

`test-delegate.sh` has 12 `/v1/models` mocks, six of which `exit 7` to force the
auto-probe to fall back to Ollama. Under the new design `/v1/models` *is*
discovery, so those need canned bodies. `test-embed.sh` has 14
`make_mock_ollama` sites plus `make_mock_curl_ok` (`:48-70`), which answers
every curl with an embeddings body and so would answer the `/models` probe with
the wrong shape.

Assertions that must survive unchanged: `run-tests.sh:136`, `:145`, `:162`
(prose and long-context ordering, the Phase 7 baseline pin), `:174` (the
dry-run pref string — `:172` asserts stdout, not the pref string), `:260`
(reasoning ordering, v6 baseline), `:469`, `:508`. Fixtures change;
expectations do not.

Assertions that must change: `:591` (`valid: auto|ollama|mlx`), `:605`/`:620`,
`:638-639` ("ollama not on PATH"), `:653`/`:666`, and the audit section
`:643-687`.

New coverage, seven cases: fallthrough when the first provider is unreachable;
fallthrough when it is reachable but holds no matching model; all providers
unreachable; probe failure not aborting under `set -e`; sorted output making a
two-match preference deterministic; empty content with `finish_reason: length`
exiting non-zero; empty content otherwise exiting non-zero. A userinfo URL
exiting 2 makes eight.

A prototype of the guard plus `--max-time` against the current tree passed every
suite unchanged: `test-delegate.sh` 556/556, `run-tests.sh` 110/110,
`test-embed.sh` 48/48, `test-delegate-feedback.sh` 226/226,
`test-delegate-boundary-hook.sh` 134/134, `test-prompts-library.sh` 288/288,
`test-metrics-summary.sh` 135/135.

## Documentation

Behavioural first: `SKILL.md:42` reads "If `ollama` is not on PATH or
`ollama list` is empty, do the work yourself and mention why." Left unchanged,
an agent on a Docker-only host stops delegating entirely — the exact scenario
driving this work. `SKILL.md:62` states delegate.sh calls `POST /api/generate`,
and `:171-178` hardcodes `http://localhost:11434/api/generate`. The frontmatter
`description` must stay byte-identical so the trigger-eval gate is provably
unaffected.

Then: `CLAUDE.md:93-105`; `CONTRIBUTING.md:11`; `SECURITY.md:11` (one sentence
noting a non-default `DELEGATE_BASE_URL` sends content off-device);
`docs/otel-schema.md:25,63,69,70,71` including the registry correction above;
`README.md:43,145,176-178,258`; `docs/install-mlx.md`,
`install-claude-code.md:42`, `install-opencode.md:34`, `install-codex.md`;
`dashboards/grafana/delegate-overview.json:727,777`, `delegate-errors.json:809`,
`dashboards/langfuse/README.md:25`; `.github/PULL_REQUEST_TEMPLATE.md:17`,
`ISSUE_TEMPLATE/bug_report.md:33-34`,
`workflows/monthly-audit-reminder.yml:5,51,57`;
`tests/fixtures/doc-section/backend-auto-probe.txt`, false wholesale.

New ADR for the collapse. Status notes on ADR 0022, and on ADRs 0002, 0006 and
0018 which rest on the two-backend split. ADR 0020 is marked Accepted but
describes a gate removed in the lean-core reset; note it superseded while
nearby.

## Risks

**Reasoning-tier latency.** Losing native `think:false` means the trace is
generated then discarded. Measured live at temperature 0.2, Ollama's OpenAI
endpoint took 133 s and 257 s on `deepseek-r1:32b` where the same tier records
p50 9.9 s / p95 42.4 s on Ollama natively (n=57) — roughly 13-26x, consistent
with ADR 0005's documented "50× wall-time cost from in-band `<think>` tokens
that bypass `think:false`". Provider-major resolution keeps the reasoning tier
on MLX where the kwarg is honoured, so this bites only when MLX is unavailable
— which is precisely the scenario driving this work. Measure in PR 2 before
merge; if material, the escape hatch is per-provider native dispatch for that
tier alone.

Note the previously quoted baseline of "p50 40.8 s, p95 83 s" was the MLX-only
figure; the tier overall is p50 29.7 s / p95 85.6 s.

**Discovery requires a running daemon.** `--print-installed` and
`audit-models.sh` report nothing when everything is stopped. Accepted, and
partly offset by Decision 6's correctness gain.

**Multi-daemon memory pressure.** A reviewer observed Docker's `llama-server`
at 53 GB driving free memory to roughly 62 MB, after which `mlx_lm.server`'s
worker went defunct while the parent still accepted TCP on 8080 without
answering — a hung first provider that burns the full probe timeout on every
delegation. ADR 0006 decided against multiple resident servers partly on these
grounds. Provider-major resolution keeps most tiers on one daemon and so
largely avoids the tier-mixing that would warm several, but the hung-provider
case is the reason `DELEGATE_PROBE_TIMEOUT` stays at 1 s rather than rising.

**Cold provider versus canary.** Docker's `/v1/models` answers instantly while
a cold 35B `/chat/completions` did not return within 25 s, and
`DELEGATE_PREFLIGHT_TIMEOUT` defaults to 10 (`:1085`). Discovery does not imply
readiness. A canary failure remains terminal rather than falling through —
resolution and dispatch stay separate — so a listed-but-cold model is a hard
exit 3. If that proves annoying in practice, raise the preflight timeout rather
than adding cross-provider retry.

## Out of scope

Embeddings (#362), `DELEGATE_API_KEY` and remote-endpoint support,
image/vision passthrough, cross-provider dispatch retry, streaming, per-tier
provider pinning, `top_k` reinstatement, changes to the preference lists, and
de-aliasing those lists (worth doing, but a separate calibration exercise).
