# OpenTelemetry export schema — attribute reference

Companion to ADR [0007 — OpenTelemetry export schema](adr/0007-otel-schema.md), which records the four decisions this reference encodes (the `gen_ai.*` vs `delegate.*` namespace split, the feedback-as-linked-span pattern, the no-content-by-default rule, and the opt-in `DELEGATE_OTEL_INCLUDE_CONTENT` flag). Treat the ADR as the rationale and this file as the wire-payload contract: Track A's exporter (issue [#134](https://github.com/IsmaelMartinez/delegate-local/issues/134)) emits the metadata attributes below unconditionally, and Track F's privacy-redaction default (issue [#158](https://github.com/IsmaelMartinez/delegate-local/issues/158)) gates content attributes behind an explicit opt-in.

## Default vs opt-in attributes

The schema splits into two tiers:

- **Metadata** — tier, model, recipe name, char counts, durations, exit status, verdict (`hit`/`miss`), parent IDs. These travel unconditionally so dashboards have the routing signal they need to count hits, misses, latencies, and tokens-avoided. None of these carry arbitrary user text.
- **Content** — the prompt the model sees, the piped context, the model's output, and the user-authored MISS reason. These are gated behind `DELEGATE_OTEL_INCLUDE_CONTENT=1` and are omitted entirely from the wire payload when the flag is unset.

The default is redact: only metadata leaves the host. Operators who explicitly want content (typically because they are pointing the exporter at a local Phoenix instance, a vetted private backend, or a debugging session) set `DELEGATE_OTEL_INCLUDE_CONTENT=1`. The flag is described in detail in the env-var docstrings inside `scripts/delegate.sh` and `scripts/delegate-feedback.sh`; the warning that content may carry PII / API keys / internal URLs lives there in lock-step with the wire schema.

The source for every attribute is one of:

- A field already present on a JSONL row written by `scripts/delegate.sh` or `scripts/delegate-feedback.sh` to `~/.claude/skills/delegate-local/metrics.jsonl`. Track A reads the row and translates each field to the attribute name listed below.
- A constant the exporter inlines (the operation name, the temperature, the span-name format).
- A value generated at delegation time by the exporter itself (the trace ID and span ID, written back to the JSONL row as `otel_trace_id` / `otel_span_id` so `delegate-feedback.sh` can correlate without a second lookup).

## Sample JSONL row used as the example below

A real recent delegation row from `~/.claude/skills/delegate-local/metrics.jsonl`:

```json
{"ts":"2026-05-21T21:46:56Z","source":"delegate","backend":"ollama","tier":"prose","model":"qwen3.6:35b-a3b-q8_0","prompt_chars":80,"context_chars":3739,"output_chars":2807,"duration_ms":19267,"queue_wait_ms":412,"generation_ms":18855,"exit_status":0,"estimated_tokens_avoided":1656}
```

Most example values in the tables below come from this row, so a reader can trace a delegation end-to-end through the exporter mapping. Two exceptions: `delegate.recipe` is shown as `doc-section` for illustration (the sample row above is a bare prose-tier call with no recipe field), and the feedback-span examples in the Feedback span section below are drawn from a separate kept-row written by `delegate-feedback.sh`, not shown here.

## Delegation span

One span per `scripts/delegate.sh` invocation.

### Resource attributes

Resource attributes are set once on the OTLP `resourceSpans.resource` envelope and apply to every span in the batch. The exporter sets exactly one resource attribute:

| Attribute | Type | Source | OTel convention | Example |
|-----------|------|--------|-----------------|---------|
| `service.name` | string | exporter-constant (`"delegate-local"`) | https://opentelemetry.io/docs/specs/semconv/resource/#service | `delegate-local` |

The constant value lets dashboards filter spans from this skill (`resource.service.name="delegate-local"`) so other GenAI workloads sharing the same collector do not bleed in.

### Span identity

| Field | Value | Source | Example |
|-------|-------|--------|---------|
| Span name | `"{gen_ai.operation.name} {gen_ai.request.model}"` | exporter-constructed | `chat qwen3.6:35b-a3b-q8_0` |
| Span kind | `CLIENT` | exporter-constant | `CLIENT` |
| Span status | `OK` when `exit_status == 0`; `ERROR` otherwise | JSONL `exit_status` | `OK` |
| Trace ID | generated at delegation time, written back to JSONL row | exporter-generated, persisted to `otel_trace_id` | 32 hex chars |
| Span ID | generated at delegation time, written back to JSONL row | exporter-generated, persisted to `otel_span_id` | 16 hex chars |
| Start time | parsed from JSONL `ts` | JSONL `ts` | `2026-05-21T21:46:56Z` |
| End time | start time plus `duration_ms` | JSONL `ts` + `duration_ms` | `2026-05-21T21:47:15.267Z` |

### OTel GenAI semantic-convention attributes (`gen_ai.*`)

All attributes in this table follow the published OTel SemConv (https://opentelemetry.io/docs/specs/semconv/gen-ai/) verbatim. The conventions are still in Development status — no attribute is yet Stable — but the names listed here are the ones Grafana Cloud's pre-built GenAI dashboards already key off, which is the reason for using them rather than a private alternative.

| Attribute | Type | Source | OTel convention | Example |
|-----------|------|--------|-----------------|---------|
| `gen_ai.operation.name` | string | exporter-constant | https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/#gen-ai-operation-name | `chat` |
| `gen_ai.provider.name` | string | JSONL `backend` | https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/#gen-ai-provider-name | `ollama` |
| `gen_ai.request.model` | string | JSONL `model` | https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/#gen-ai-request-model | `qwen3.6:35b-a3b-q8_0` |
| `gen_ai.request.temperature` | number | hardcoded `0` in `delegate.sh` | https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/#gen-ai-request-temperature | `0` |

Notes on each:

- `gen_ai.operation.name` is always `chat`. The OTel SemConv enumerates `chat`, `text_completion`, `embeddings`, and others; this skill routes through Ollama's `/api/generate` (the raw completion endpoint — chat templating is applied by `scripts/delegate.sh` shaping the prompt before posting, not by the Ollama daemon) and MLX's `/v1/chat/completions` (OpenAI-compatible, applies the model's chat template server-side). Despite the endpoint asymmetry both calls are chat-shaped from the user's perspective, so `chat` is the accurate value for both backends.
- `gen_ai.provider.name` is set from the JSONL `backend` field. Both `ollama` and `mlx` are already registered as provider strings in the SemConv registry, so the values are conventional rather than ad-hoc.
- `gen_ai.request.model` is the model tag as Ollama or MLX sees it — `qwen3.6:35b-a3b-q8_0` for Ollama, `mlx-community/Qwen3.6-35B-A3B-8bit` for MLX. The raw tag is preserved so downstream filtering and grouping work against the same identifier a user would type into `ollama run` or `mlx_lm.generate`.
- `gen_ai.request.temperature` is hardcoded to `0` in `scripts/delegate.sh` (the skill never varies it). Emitting the attribute is still useful because Grafana's GenAI dashboards group by temperature when set.

### Private skill-specific attributes (`delegate.*`)

Attributes the OTel WG does not cover. The `delegate.*` prefix follows the SemConv guidance that vendors and applications use a custom namespace for fields outside the canonical conventions. Rationale for the namespace boundary lives in ADR 0007.

#### Metadata attributes (unconditional)

These always travel — they are structured routing signal, not arbitrary user text.

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.tier` | string | JSONL `tier` | private | `prose` |
| `delegate.recipe` | string | JSONL `recipe` (optional — only when `--recipe` was used) | private | `doc-section` |
| `delegate.project` | string | JSONL `project` (basename of the git toplevel, or cwd outside a repo) | private | `delegate-local` |
| `delegate.prompt_chars` | int | JSONL `prompt_chars` | private | `80` |
| `delegate.context_chars` | int | JSONL `context_chars` | private | `3739` |
| `delegate.output_chars` | int | JSONL `output_chars` | private | `2807` |
| `delegate.queue_wait_ms` | int | JSONL `queue_wait_ms` | private | `412` |
| `delegate.generation_ms` | int | JSONL `generation_ms` | private | `18855` |
| `delegate.estimated_tokens_avoided` | int | JSONL `estimated_tokens_avoided` | private | `1656` |
| `delegate.exit_status` | int | JSONL `exit_status` | private | `0` |

Notes on each:

- `delegate.tier` is the routing tier `pick-model.sh` resolved (`code`, `prose`, `reasoning`, `long-context`, or one of the scaffolded tiers once they go live). Dashboards group by tier to track per-tier hit rate and per-tier tokens-avoided.
- `delegate.recipe` is present only when the caller used `delegate.sh --recipe NAME`. Bare-prose-tier calls omit it; the exporter SHOULD NOT emit the attribute with an empty string. The `delegate.recipe` attribute is what dashboards group by to track per-recipe hit/miss rates, which is the load-bearing signal for the prompt-library calibration work.
- `delegate.project` is the basename of the git toplevel (or the cwd when not in a repo) at the time `delegate.sh` ran. It attributes each delegation to the repo it came from, so a single shared Tempo/Grafana backend can be scoped per-repo via the dashboards' `$project` filter variable. Note that git worktrees resolve to their own basename, so worktrees of one repo appear as distinct project values.
- `delegate.prompt_chars` / `delegate.context_chars` / `delegate.output_chars` are character counts only. They travel unconditionally as the metadata replacement for the content fields — dashboards correlate latency and verdict against input/output size without needing the text itself. The matching `delegate.prompt` / `delegate.context` / `delegate.output` content attributes are gated separately (see below).
- `delegate.queue_wait_ms` and `delegate.generation_ms` split the JSONL `duration_ms` total per the gotcha #170 telemetry fix: `queue_wait_ms` is the wall-clock from `delegate.sh` invoking the backend HTTP endpoint to the first byte returned (parallel-caller contention surfaces here), and `generation_ms` is first-byte to response-complete (the model's own decode time). The two sum to `duration_ms` within rounding. Dashboards keep both histograms so a slow tail can be attributed to queue pressure versus generation pressure rather than being hidden in a single `duration_ms` blob.
- `delegate.estimated_tokens_avoided` is the tokens-avoided counter the skill's README headlines as one of the two core values (the other being on-device privacy). It is the central rollup metric for the per-tier and per-recipe panels in Track D's dashboards.
- `delegate.exit_status` is critical to surface as a filterable attribute because `exit_status:3` rows are the canary-failure case (preflight probe timed out — see the canary mitigation note in CLAUDE.md). Track D's dashboard set includes an exit-status-3 rate panel that filters on this attribute. The span status is independently set to `ERROR` when `exit_status != 0`, so backends that don't easily filter by attribute can still surface failures via the standard mechanism.

#### Content attributes (gated on `DELEGATE_OTEL_INCLUDE_CONTENT=1`)

These carry arbitrary user text and only travel when the operator explicitly opts in. When the flag is unset or `0`, the attributes are omitted from the wire payload entirely — no `<redacted>` sentinel, just absence. The char-count metadata above is the unconditional replacement so dashboards keep working without the leak.

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.prompt` | string | `recipe_template` + `prompt` arg (matches `prompt_chars`) | private, gated | `Draft a git commit message from the staged diff …` |
| `delegate.context` | string | piped stdin (matches `context_chars`) | private, gated | `diff --git a/scripts/delegate.sh …` |
| `delegate.output` | string | model response (matches `output_chars`) | private, gated | `feat: privacy redaction default for OTel exporter` |

Notes on each:

- `delegate.prompt` is the prompt the model sees — the recipe template (when `--recipe` is used) concatenated with the trailing prompt argument. The char count for this field is `delegate.prompt_chars`.
- `delegate.context` is the piped stdin content. The char count is `delegate.context_chars`. When `{{stdin}}` is used inside a recipe template, the content is duplicated into `delegate.prompt`'s post-substitution form; the raw stdin is still emitted here for completeness.
- `delegate.output` is the model's response text (the bytes that landed on stdout for the caller). The char count is `delegate.output_chars`.
- Empty-content omission: when `DELEGATE_OTEL_INCLUDE_CONTENT=1` is set but any individual content field has an empty value (no piped stdin, failure span before the model responded, etc.), that specific attribute is omitted from the payload rather than emitted as `stringValue: ""`. This matches the `delegate.recipe` convention so consumers can rely on attribute presence as a meaningful signal that content exists. The char-count metadata still shows `0` so size telemetry remains continuous across the empty/non-empty boundary.
- Why this is opt-in: any of these three may contain PII, API keys, internal URLs, customer data, or anything else that happened to be in the caller's clipboard / repo / shell context. The skill's README and SKILL.md both frame on-device privacy as a primary value; gating these fields keeps the default behaviour consistent with that framing. Operators with a vetted local-only collector (a Phoenix instance, a Langfuse-self-hosted deployment, a dev-only OTLP endpoint behind a firewall) can flip the flag for richer debugging.

## Feedback span

One span per `scripts/delegate-feedback.sh` invocation. New trace, new span ID, with the parent delegation's trace ID and span ID carried in the `links` array and (belt-and-braces) as plain string attributes. The feedback-as-linked-span pattern's rationale lives in ADR 0007.

### Span identity

| Field | Value | Source | Example |
|-------|-------|--------|---------|
| Span name | `"feedback {gen_ai.request.model}"` | exporter-constructed | `feedback qwen3.6:35b-a3b-q8_0` |
| Span kind | `INTERNAL` | exporter-constant | `INTERNAL` |
| Span status | `OK` always | exporter-constant | `OK` |
| Trace ID | newly generated for this span | exporter-generated | 32 hex chars |
| Span ID | newly generated | exporter-generated | 16 hex chars |
| `links` array | `[{traceId: <parent>, spanId: <parent>}]` | parent delegation's JSONL `otel_trace_id` + `otel_span_id` | one link entry |
| Start time | parsed from feedback row's `ts` | feedback JSONL `ts` | `2026-05-21T21:47:42Z` |
| End time | start time plus a fixed short duration (1 ms) | exporter-constant | `2026-05-21T21:47:42.001Z` |

The feedback span is short by design — it is a marker event, not a unit of work. The 1 ms end-time bump keeps it visible in span lists; OTel does not allow zero-duration spans on all backends.

### Feedback-specific attributes

#### Metadata attributes (unconditional)

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.feedback.verdict` | string (`hit` or `miss`) | feedback JSONL `kept` (true → `hit`, false → `miss`) | private | `hit` |
| `delegate.feedback.parent_trace_id` | string | parent delegation's JSONL `otel_trace_id` | private (fallback for backends that don't render `links` well) | 32 hex chars |
| `delegate.feedback.parent_span_id` | string | parent delegation's JSONL `otel_span_id` | private (fallback for backends that don't render `links` well) | 16 hex chars |
| `delegate.recipe` | string | parent delegation's JSONL `recipe` (optional — only when `--recipe` was used) | private | `commit-message` |

Notes on each:

- `delegate.feedback.verdict` collapses the JSONL `kept` boolean to a string. The string form makes dashboard group-by clauses readable (`group by delegate.feedback.verdict` reads as `hit` / `miss` rather than `true` / `false`).
- `delegate.feedback.parent_trace_id` and `delegate.feedback.parent_span_id` duplicate the `links` array as plain string attributes for backends that do not render `links` well in their default trace view. Backends that handle `links` correctly use the standard mechanism; backends that don't can still filter and join on the attribute. The fallback is intentionally redundant.
- `delegate.recipe` (#187) is duplicated from the parent delegate span onto the feedback span so per-recipe HIT-rate dashboards become single-query panels. TraceQL does not support cross-trace projection cleanly — a query of the form "verdict distribution grouped by the parent's recipe" needs the recipe attribute physically present on the feedback span, not just reachable through a `links` traversal. Recipe names are short predefined identifiers from `prompts/<NAME>.md` (not arbitrary user content), so the attribute travels unconditionally — the `DELEGATE_OTEL_INCLUDE_CONTENT` content gate does not apply. Omitted when the parent delegation was a bare-tier call without `--recipe`, consistent with the parent delegate span's recipe handling.

#### Content attributes (gated on `DELEGATE_OTEL_INCLUDE_CONTENT=1`)

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.feedback.reason` | string | feedback JSONL `reason` | private, gated | `clean prose, no padding tails, one spelling fix needed (labeled → labelled for UK English)` |

Notes on each:

- `delegate.feedback.reason` carries the free-text reason the user typed when recording a MISS (or a HIT, when the caller chose to annotate it). The reason field is the input to the miss-reason word cloud and top-N panels in Track D. It is gated behind `DELEGATE_OTEL_INCLUDE_CONTENT=1` because the field is user-authored free text and historically callers have pasted prompt fragments, model output excerpts, file paths, and customer identifiers into MISS reasons when debugging. When the flag is unset the verdict and parent IDs still travel (the dashboard still counts hits and misses); the reason text stays on-host in the JSONL row.
- Backwards-compat note: prior to Track F (issue #158, 2026-05-22) the reason was emitted unconditionally. Callers who already export feedback to a trusted collector and want the reason in the dashboard must set `DELEGATE_OTEL_INCLUDE_CONTENT=1` to restore the previous behaviour.

## What the exporter does NOT emit

The following OTel-defined attribute names are NEVER present in the payload, regardless of env-var settings, because Phase 11 chose a private namespace for content rather than the WG-defined attributes:

- `gen_ai.prompt` (opt-in in the SemConv; not used by this skill — content travels as `delegate.prompt` when enabled)
- `gen_ai.completion` (opt-in in the SemConv; not used by this skill — content travels as `delegate.output` when enabled)
- Any `delegate.prompt_text`, `delegate.output_text`, `delegate.context_text` attribute name (deprecated drafts during Track A review; the final names are `delegate.prompt`, `delegate.context`, `delegate.output`)

Track F's redaction test (issue #158) is the tested invariant that backs the gated-by-default rule. It asserts that with `DELEGATE_OTEL_INCLUDE_CONTENT` unset, no `delegate.prompt`, `delegate.context`, `delegate.output`, or `delegate.feedback.reason` attribute is present in the OTLP body. With the flag set, those four attributes are present and carry their JSONL-row values verbatim. A future change that wants to add a new content-bearing attribute must extend the same gate in lock-step.
