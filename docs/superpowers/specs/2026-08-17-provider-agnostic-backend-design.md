# Provider-agnostic backend: one OpenAI-compatible driver

Date: 2026-08-17

## Status

Approved in principle, revised after a four-reviewer pass on the first draft.
The review invalidated three decisions in that draft; this version records the
corrections and stages the work, because the blast radius turned out to be
roughly ten times what the first draft assumed.

Supersedes the two-backend model in ADR 0022 (whose performance rationale for
preferring MLX still stands; only the selection mechanism changes).

## Context

`delegate.sh` and `pick-model.sh` hardcode two backends. Ollama is called at
`POST /api/generate` with a `think` field and a nested `options` object; MLX at
`POST /v1/chat/completions` in the OpenAI shape. Discovery is equally forked:
`ollama list` parsed with awk, versus a filesystem scan of `$HF_HOME/hub`.
`DELEGATE_BACKEND` accepts `auto|ollama|mlx`.

In August 2026 device policy on the primary workstation began blocking
`huggingface.co` at the socket layer, so the MLX cache can no longer be
populated, and Ollama is expected to be blocked by the same policy. Docker
Model Runner is reachable, serves an OpenAI-compatible API at
`http://localhost:12434/engines/v1`, and mirrors `mlx-community` weights as OCI
artifacts. Adding it as a third hardcoded backend would mean three dispatch
branches and three discovery branches.

All three runtimes already expose `GET /v1/models` and
`POST /v1/chat/completions`. The fork is unnecessary.

### Measured during design

- Ollama's `GET /v1/models` returns the same set as `ollama list`.
- Ollama's OpenAI endpoint ignores `chat_template_kwargs.enable_thinking=false`:
  `deepseek-r1:14b` still produced a 1704-character trace. It does **not**
  return an empty answer — with `max_tokens: 4096` the answer arrives in
  `.content` and the trace is in `.reasoning`. An earlier reading that content
  is always empty was an artifact of a 300-token cap truncating mid-trace.
- With the budget exhausted, Ollama returns `"content": ""` (empty string, not
  `null`) and `finish_reason: "length"`.
- `mlx_lm` 0.31.3 `server.py` registers only `/v1/chat/completions`,
  `/v1/completions`, `/v1/models`. No `/v1/embeddings`.
- Docker Model Runner serves `GET /v1/models` and `POST /v1/chat/completions`
  at `http://localhost:12434/engines/v1`.
- Docker's `ai/qwen3.6:35b-mlx` manifest carries
  `ai.model.repo=mlx-community/Qwen3.6-35B-A3B-nvfp4`, so Docker Hub is a
  viable transport for the same weights HuggingFace would serve.

## Corrections forced by review

These three killed decisions in the first draft and are the reason for staging.

**C1 — `//` does not fall through on an empty string.** The draft parsed
`.choices[0].message.content // .choices[0].message.reasoning`. jq's alternative
operator only triggers on `null` or `false`. Ollama returns `""`, so the
fallback was dead code. This bug already exists at `delegate.sh:1243` and is
inherited, not introduced. Corrected below.

**C2 — a `.reasoning` fallback is unsafe even when reached.**
`DELEGATE_STRIP_THINK` strips on a literal `</think>` substring
(`delegate.sh:1261`). Ollama's `reasoning` field has the delimiters already
removed, so the strip is a no-op and raw chain-of-thought would be returned as
the answer, exit 0. Strip also defaults on only for the `reasoning` tier
(`delegate.sh:1256-1260`), so a thinking model on `prose` would leak a trace.
The fallback is removed entirely.

**C3 — the resolution loop must be preference-major, not provider-major.** The
draft looped providers outermost, which makes provider order dominate model
quality and contradicts `pick-model.sh:15` ("highest capability first") and
ADR 0003. Reproduced against the three live daemons: the code tier resolved to
`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` on MLX when the top
preference `qwen3-coder-next:latest` was installed and reachable on Ollama.

## Decisions

1. **One driver.** The Ollama-native dispatch path is deleted; every provider is
   called at `POST {base}/chat/completions`.
2. **Providers are base URLs.** No provider-name registry in the chat path.
3. **Resolution is preference-major.** Every reachable provider's model list is
   fetched once, then preferences are walked in order and, for each, providers
   in order. Capability dominates; provider order is only the tiebreak.
4. **Loopback only.** Base URLs must resolve to a loopback host. A non-loopback
   URL is a usage error (exit 2), not a warning. Remote endpoints are a separate
   decision requiring a `SECURITY.md` change, and are out of scope.
5. **Scope is chat generation.** `embed.sh` and the embedding tier are untouched
   beyond one line; issue #362 tracks the rest.
6. **The HuggingFace cache scan is removed.** Discovery is only ever "what a
   running provider reports".

### Why loopback-only, given "provider agnostic"

`SECURITY.md:11` states outbound calls go only to a local Ollama or MLX host,
and the skill's headline value is keeping content on-device. Allowing arbitrary
hosts silently voids that promise. Reviewers also showed that a URL-borne
credential (`https://key@host/v1`) would land in `gen_ai.provider.name`, which
sits outside the `DELEGATE_OTEL_INCLUDE_CONTENT` redaction gate
(`lib/otel.sh:260`, gate at `:273-278`), and that any real-time warning would be
swallowed because `delegate.sh:915-920` captures pick-model's stderr and prints
it only on failure. `DELEGATE_API_KEY` is therefore **not** introduced. The
design still supports any OpenAI-compatible endpoint; it is honest that the
endpoints in scope are local ones.

## Configuration surface

```sh
DELEGATE_PROVIDERS   # space-separated ordered list of base URLs. Replaces the
                     # defaults entirely when set (it does not extend them).
                     # Default: "http://localhost:8080/v1
                     #           http://localhost:12434/engines/v1
                     #           http://localhost:11434/v1"
                     # Split with `read -ra`; newlines and repeated spaces are
                     # tolerated. Each entry has one trailing slash stripped.

DELEGATE_BASE_URL    # optional single URL, prepended to the list above.
                     # Tier-fallthrough still applies after it.

DELEGATE_PROBE_TIMEOUT    # seconds per /models probe. Default 2.
                          # Replaces DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT, which
                          # is removed (asserted in test-delegate.sh:943).

DELEGATE_REQUEST_TIMEOUT  # seconds for the dispatch POST. Default 300. NEW —
                          # the dispatch curl has no --max-time today
                          # (delegate.sh:1207, :1239), so a provider that
                          # answers /models then stalls hangs indefinitely.
```

`DELEGATE_BACKEND` is removed. Pinning to one provider is
`DELEGATE_PROVIDERS="<single url>"`.

## pick-model.sh

Removed: `auto_resolve_backend()` (102-110), `backend_requested=` and its case
(112-122), both branches of `list_installed()` (130-163).

Added:

```sh
provider_models <base_url>   # GET {base}/models with --max-time
                             # $DELEGATE_PROBE_TIMEOUT; prints `.data[].id`
                             # sorted; returns 1 on unreachable/non-2xx/malformed.
```

Output is **sorted**. The removed hub scan was glob-ordered and therefore
stable; Ollama's `/v1/models` is recency-ordered and Docker's order is
undocumented, so with a `grep -im1` matcher an unsorted list makes resolution
non-deterministic when one preference matches two entries (Ollama holds both
`deepseek-r1:14b` and `deepseek-r1:32b`).

Resolution, after the prefs array and the `config.sh` override are applied
exactly as today:

```
providers = split(DELEGATE_BASE_URL + DELEGATE_PROVIDERS)
reachable = []
for base in providers:
    models = provider_models(base) || continue    # explicit || — see below
    reachable += (base, models)
for p in prefs:                  # preference-major: capability dominates
    for (base, models) in reachable:
        match = first case-insensitive fixed-string hit of p in models
        if match: emit (base, match); exit 0
exit 1
```

`pick-model.sh` runs under `set -euo pipefail` (line 40). A command substitution
that fails aborts the script, so `provider_models` must be called with an
explicit failure branch (`if ! models=$(provider_models "$base"); then continue; fi`).
Written as a bare assignment, a stopped MLX server would abort resolution before
Docker or Ollama were tried — the exact inverse of decision 3.

### Command surfaces

- `pick-model.sh <tier>` — unchanged contract: prints the model on stdout.
  Implemented as a field-cut of the resolution below, so there is one loop.
- `pick-model.sh --print-resolution <tier>...` — new, and the single entry
  point. Accepts one or more tiers, emits `tier<TAB>base_url<TAB>model` per
  line. Accepting several tiers bounds probe cost: `audit-models.sh` resolves
  eight tiers in one invocation and therefore one probe round, replacing the
  `export DELEGATE_BACKEND` pinning idiom it uses today for the same purpose
  (`audit-models.sh:23-25`). It preserves the exit-1 versus exit-2 distinction
  `delegate.sh:920-941` depends on.
- `pick-model.sh --print-backend` — **removed**. Retaining the name with a new
  meaning would leave `audit-models.sh` exiting 0 while reporting a header that
  does not describe what its tier rows did: `:27` and `:41` compare against
  `"ollama"`, `:33` and `:147` against `"mlx"`, and `:63` against `!= "ollama"`,
  all of which silently take the wrong arm against a URL. A removal fails loudly.
- `pick-model.sh --print-installed` — prints every reachable provider's models,
  grouped by base URL. "First reachable provider" would misreport inventory in
  the same way.
- `--print-prefs` and `--dry-run` are retained; traces gain the base URL probed
  and why each provider was skipped.

### config.sh and the destination host

Today `config.sh` can only reorder `prefs`, so its worst outcome is a different
local model. Under this design it is sourced before resolution and could set
`DELEGATE_PROVIDERS`, making it choose where prompts are sent. The default path
`$HOME/.claude/skills/delegate-local/config.sh` (`pick-model.sh:209`) resolves
through the install symlink to `<repo>/config.sh`, so a branch adding a *tracked*
`config.sh` would place executable bash there; `.gitignore` does not prevent a
tracked file materialising, and the ownership and mode guards (`:216-235`) both
pass for a normal checkout.

Mitigation, required: the provider list is resolved and frozen **before**
`config.sh` is sourced, and any assignment to `DELEGATE_PROVIDERS` or
`DELEGATE_BASE_URL` from within it is ignored with a warning. The override keeps
its existing power over `prefs` and gains none over the destination. Combined
with decision 4 (loopback-only), the pre-existing "single-user dev" threat model
in the cited retrospective remains valid rather than being silently widened.

## delegate.sh

Removed: `backend_requested` and the probe case (385-403), `ollama_host` (404)
and `mlx_host` (405), the dispatch branch (1194-1247) including the entire
`/api/generate` payload, and the two-way canary block (1096-1104) with both
payload shapes.

Dispatch keeps the request the MLX branch already builds — `model`, `messages`,
`stream:false`, `temperature`, `max_tokens`,
`chat_template_kwargs.enable_thinking`, plus optional `top_p` and
`presence_penalty` — posted to `{base}/chat/completions` with
`--max-time $DELEGATE_REQUEST_TIMEOUT`.

`top_k` is dropped from the payload. It is not an OpenAI chat-completions
parameter; `delegate.sh:1229-1231` notes MLX accepts it as an extension, but
whether Ollama's shim and Docker accept, ignore, or reject it is unverified, and
a strict provider returning 400 would turn `DELEGATE_TOP_K` into a hard dispatch
failure. Verify per provider before reinstating.

### Response parsing

```
content      = .choices[0].message.content        # may be ""
finish       = .choices[0].finish_reason
```

If `content` is non-empty, that is the output. There is no `.reasoning`
fallback (C2). If `content` is empty:

- `finish == "length"` → exit non-zero with a message naming
  `DELEGATE_MAX_TOKENS` and explaining that a thinking model consumed the budget
  before answering.
- otherwise → exit non-zero as an empty-response error.

Both replace today's silent success-with-empty-output, which writes a metrics
row with `output_chars: 0` and fires the verdict nudge asking the operator to
grade nothing. Emptiness must be tested with `== ""`, never jq `//` (C1).

### DELEGATE_MAX_TOKENS becomes universal

It is documented MLX-only (`delegate.sh:207`) and read only in the MLX branch
(`:1225`); the Ollama branch sets no `num_predict`, so Ollama output is
effectively uncapped today. Collapsing applies the 4096 default to every call.
This is why the `finish_reason` check above is mandatory rather than nice to
have: without it, long-context and reasoning outputs would truncate silently.

### Canary

The preflight canary is retained and posts to `{base}/chat/completions`. A
canary failure is treated the same as a dispatch failure: it does **not** fall
through to the next provider. Resolution and dispatch stay separate; adding
cross-provider dispatch retry is out of scope. Recovery text at `:1118`, `:1127`
and `:1276` is rewritten to name the base URL and the probed list instead of
`ollama serve` / `mlx_lm.server` and `OLLAMA_HOST` / `MLX_HOST`.

## Metrics and OTel

The JSONL `backend` field keeps a short provider **label**, and a new
`base_url` field carries the URL. The label is derived by matching the base URL
against the three known defaults (`mlx`, `docker`, `ollama`), falling back to
`openai`. This four-line mapping is not optional decoration: `lib/otel.sh:260`
maps `backend` to `gen_ai.provider.name`, which `docs/otel-schema.md:70` pins to
registered SemConv provider strings, and
`dashboards/grafana/delegate-overview.json:777` and `delegate-errors.json:809`
aggregate `sum by (backend)` with `{{backend}}` legends. Emitting URLs there
would break a documented wire contract, turn dashboard legends into URLs, and
split the same daemon into two unrelated series across the cutover.

`base_url` maps to the OTel `server.address` attribute. `docs/otel-schema.md`
gains a row for it. `metrics-summary.sh` reads `.backend // "ollama"`
(`:144,152,154`) and gates its section on more than one distinct value (`:148`);
keeping labels means that behaviour is preserved and historical rows remain
comparable.

`embed.sh` continues writing the literal `ollama` label (`:162,165`), which
stays correct under this scheme rather than becoming a mixed enum-and-URL
stream.

## embed.sh

One line. `:175` becomes
`DELEGATE_PROVIDERS="${OLLAMA_HOST:-http://localhost:11434}/v1" bash "$pick" embedding`,
with a scheme guard: Ollama's own convention for `OLLAMA_HOST` is a bare
`host:port`, which would otherwise produce a schemeless string. Everything else
in `embed.sh` is untouched; issue #362 tracks the rest.

## Staging

The first draft treated this as one change. Review showed it spans roughly
fifteen files of code and five test files, so it ships in four PRs:

**Phase 1 — bug fixes, independent of any provider work.** Fix the `//`
empty-string parse at `delegate.sh:1243` and add `--max-time` to the dispatch
curl. Both are live defects today; both are small and independently testable.

**Phase 2 — collapse dispatch.** Delete the `/api/generate` branch so every call
uses the OpenAI shape, keeping discovery and `DELEGATE_BACKEND` exactly as they
are. This is where the response-parsing, `max_tokens` and `finish_reason`
decisions land, and where the reasoning-tier latency regression is measured.

**Phase 3 — providers as base URLs.** Replace discovery, remove
`DELEGATE_BACKEND`, add `--print-resolution`, implement preference-major
resolution, rework `audit-models.sh` and the test harness.

**Phase 4 — documentation, dashboards, ADRs.**

Phases 1 and 2 deliver most of the value and can land before the workstation
loses Ollama. Phase 3 carries nearly all the risk and churn.

## Testing

### Hermeticity is the load-bearing constraint

`run-tests.sh:76` injects `DELEGATE_BACKEND=ollama` into all 48 `$PICK`
invocations via the `run()` helper, and `run()` uses `env -i` with
`SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"` (`:11`), which contains the real
`/usr/bin/curl`. Today the Ollama pin means those tests perform zero HTTP.
Under this design every one of them would issue real requests to localhost,
passing on a developer machine for the wrong reason and passing in CI by
timing out.

So Phase 3 must land a per-URL curl mock injected by `run()` itself, not
per-test. The existing `make_mock_curl` (`run-tests.sh:519-526`) is a two-line
`exit N` stub with no routing and no `/v1/models` body. The argv-aware pattern
to extend already exists at `test-delegate.sh:720` and handles `-o` and `-w`.

`test-delegate.sh` carries twelve curl mocks doing `*"/v1/models"*) exit 7` to
force the auto-probe to fall back to Ollama (`:69,121,733,910,1510,1714,1795,
1865,2877,3149,3907,3976`). Under the new design `/v1/models` *is* discovery, so
`exit 7` means "nothing reachable" and each fails before dispatch. All twelve
need canned model-list bodies.

`test-embed.sh` has no pinning line to update; it has `make_mock_ollama()`
(`:31-46`) used by 13 tests and `make_mock_curl_ok()` (`:48-70`) which returns an
embeddings body for *every* curl call, so it would answer the `/models` probe
with the wrong shape. Blocks at `:221-229`, `:232-240` and `:336-346` assert on
`DELEGATE_BACKEND` directly.

### Assertions that must survive unchanged

`run-tests.sh:136`, `:145`, `:162` (prose/long-context ordering, the Phase 7
baseline pin), `:174` (dry-run pref string — note `:172` asserts stdout, not the
pref string, contrary to the first draft), `:260` (reasoning ordering, v6
baseline), `:469`, `:508`. Their fixtures change; their expectations do not.

Assertions that must change: `:591` (`valid: auto|ollama|mlx`), `:605`/`:620`
(`--print-backend` prints `ollama`/`mlx`), `:638-639` ("ollama not on PATH"),
`:653`/`:666` (`in effect:`), and the audit section `:643-687`.

### New coverage

Preference-major resolution across providers (the top preference on the *last*
provider wins over a lower preference on the first — the C3 regression, which no
existing single-provider fixture can catch); all providers unreachable; reachable
but nothing matching; `provider_models` failure not aborting under `set -e`;
sorted model output making a two-match preference deterministic;
`--print-resolution` emitting `tier<TAB>base<TAB>model` for multiple tiers in one
probe round; a non-loopback URL exiting 2; `config.sh` attempting to set
`DELEGATE_PROVIDERS` being ignored with a warning; empty `content` with
`finish_reason: length` exiting non-zero; empty `content` otherwise exiting
non-zero; the resolution-to-dispatch handoff, that `delegate.sh` posts to the
base URL `--print-resolution` returned rather than the first in the list.

## Documentation

Behavioural first: **`SKILL.md:42`** reads "If `ollama` is not on PATH or
`ollama list` is empty, do the work yourself and mention why." That is an
instruction to the assistant. Left unchanged, an agent on a Docker-only host
stops delegating entirely — the exact August 2026 scenario driving this work.
`SKILL.md:62` states delegate.sh calls Ollama's `POST /api/generate`, and
`:171-178` hardcodes `http://localhost:11434/api/generate` in the vision
snippet. The frontmatter `description` must remain byte-identical
(`git diff main -- SKILL.md` limited to the body), so the trigger-eval gate is
provably unaffected.

Then: `CLAUDE.md:93-105`; `CONTRIBUTING.md:11`; `SECURITY.md:11`;
`docs/otel-schema.md:25,63,69,70,71`; `README.md:43,145,176-178,258`;
`docs/install-mlx.md`, `install-claude-code.md:42`, `install-opencode.md:34`,
`install-codex.md`; `dashboards/grafana/delegate-overview.json:727,777`,
`delegate-errors.json:809`, `dashboards/langfuse/README.md:25`;
`.github/PULL_REQUEST_TEMPLATE.md:17`, `ISSUE_TEMPLATE/bug_report.md:33-34`,
`workflows/monthly-audit-reminder.yml:5,51,57`;
`tests/fixtures/doc-section/backend-auto-probe.txt` (false wholesale). New ADR
for the collapse; status notes on ADR 0022 and on ADRs 0002, 0006, 0018 which
rest on the two-backend split. ADR 0020 is marked Accepted but describes a gate
removed in the lean-core reset; note it as superseded while nearby.

### A self-blocking dependency

`.github/PULL_REQUEST_TEMPLATE.md:17` mandates
`bash scripts/eval-skill-triggers.sh --ollama` for SKILL.md changes, and that
script posts to `${OLLAMA_HOST}/api/generate` (`:182,193`) with its own backend
handling. On a workstation where Ollama is blocked, the gate this spec requires
cannot run. Migrating it to the shared driver is therefore in scope for Phase 4,
not optional.

## Risks

**Reasoning-tier latency on Ollama.** Losing native `think:false` means the
trace is generated then discarded rather than never produced. That tier already
measures p50 40.8 s, p95 83 s. Measure in Phase 2 against a fixed fixture; if the
regression is material, the escape hatch is per-provider native dispatch for that
tier alone, added later.

**Probe cost.** Three probes replace one. Refused loopback connections are
instant, but a provider that accepts TCP and hangs costs the full timeout — a
reviewer measured 2.14 s against such a listener. Worst case is 6 s of
pre-dispatch latency at the 2 s default. `--print-resolution` taking multiple
tiers bounds the `audit-models.sh` case to one round rather than up to 25.

**Discovery requires a running daemon.** `--print-installed` and
`audit-models.sh` report nothing when everything is stopped, where the MLX
inventory was previously readable from disk. Accepted.

**Breaking change surface.** `DELEGATE_BACKEND` disappears across `embed.sh`,
`audit-models.sh`, five test files, the README, `CLAUDE.md` and several ADRs.
Churn rather than risk, and the reason for staging.

## Out of scope

Embeddings (#362), remote/non-loopback endpoints and `DELEGATE_API_KEY`,
image/vision passthrough, cross-provider dispatch retry, streaming, per-tier
provider pinning, `top_k` reinstatement, changes to the tier preference lists,
and `init.sh`'s Ollama-only inventory bootstrap (`:17-25`), which degrades
gracefully via `onboard.sh:50-59` and is tracked separately if it matters.
