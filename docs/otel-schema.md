# OpenTelemetry export schema — attribute reference

Companion to ADR [0007 — OpenTelemetry export schema](adr/0007-otel-schema.md), which records the three decisions this reference encodes (the `gen_ai.*` vs `delegate.*` namespace split, the feedback-as-linked-span pattern, the no-content rule). Treat the ADR as the rationale and this file as the wire-payload contract: Track A's exporter (issue [#134](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/134)) emits exactly the attributes listed below, and Track F's privacy-redaction test (issue #158) asserts no other content-bearing attribute is ever present.

The source for every attribute is one of:

- A field already present on a JSONL row written by `scripts/delegate.sh` or `scripts/delegate-feedback.sh` to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Track A reads the row and translates each field to the attribute name listed below.
- A constant the exporter inlines (the operation name, the temperature, the span-name format).
- A value generated at delegation time by the exporter itself (the trace ID and span ID, written back to the JSONL row as `otel_trace_id` / `otel_span_id` so `delegate-feedback.sh` can correlate without a second lookup).

## Sample JSONL row used as the example below

A real recent delegation row from `~/.claude/skills/delegate-to-ollama/metrics.jsonl`:

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
| `service.name` | string | exporter-constant (`"delegate-to-ollama"`) | https://opentelemetry.io/docs/specs/semconv/resource/#service | `delegate-to-ollama` |

The constant value lets dashboards filter spans from this skill (`resource.service.name="delegate-to-ollama"`) so other GenAI workloads sharing the same collector do not bleed in.

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

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.tier` | string | JSONL `tier` | private | `prose` |
| `delegate.recipe` | string | JSONL `recipe` (optional — only when `--recipe` was used) | private | `doc-section` |
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
- `delegate.prompt_chars` / `delegate.context_chars` / `delegate.output_chars` are character counts only. They are NOT a stand-in for the content itself — ADR 0007's no-content rule is strict and Track F's redaction test asserts the rule as a tested invariant. The three counts let dashboards correlate latency and verdict against input/output size without leaking anything sensitive.
- `delegate.queue_wait_ms` and `delegate.generation_ms` split the JSONL `duration_ms` total per the gotcha #170 telemetry fix: `queue_wait_ms` is the wall-clock from `delegate.sh` invoking the backend HTTP endpoint to the first byte returned (parallel-caller contention surfaces here), and `generation_ms` is first-byte to response-complete (the model's own decode time). The two sum to `duration_ms` within rounding. Dashboards keep both histograms so a slow tail can be attributed to queue pressure versus generation pressure rather than being hidden in a single `duration_ms` blob.
- `delegate.estimated_tokens_avoided` is the tokens-avoided counter the skill's README headlines as one of the two core values (the other being on-device privacy). It is the central rollup metric for the per-tier and per-recipe panels in Track D's dashboards.
- `delegate.exit_status` is critical to surface as a filterable attribute because `exit_status:3` rows are the canary-failure case (preflight probe timed out — see the canary mitigation note in CLAUDE.md). Track D's dashboard set includes an exit-status-3 rate panel that filters on this attribute. The span status is independently set to `ERROR` when `exit_status != 0`, so backends that don't easily filter by attribute can still surface failures via the standard mechanism.

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

| Attribute | Type | Source | Reference | Example |
|-----------|------|--------|-----------|---------|
| `delegate.feedback.verdict` | string (`hit` or `miss`) | feedback JSONL `kept` (true → `hit`, false → `miss`) | private | `hit` |
| `delegate.feedback.reason` | string | feedback JSONL `reason` | private | `clean prose, no padding tails, one spelling fix needed (labeled → labelled for UK English)` |
| `delegate.feedback.parent_trace_id` | string | parent delegation's JSONL `otel_trace_id` | private (fallback for backends that don't render `links` well) | 32 hex chars |
| `delegate.feedback.parent_span_id` | string | parent delegation's JSONL `otel_span_id` | private (fallback for backends that don't render `links` well) | 16 hex chars |

Notes on each:

- `delegate.feedback.verdict` collapses the JSONL `kept` boolean to a string. The string form makes dashboard group-by clauses readable (`group by delegate.feedback.verdict` reads as `hit` / `miss` rather than `true` / `false`).
- `delegate.feedback.reason` carries the free-text reason the user typed. The reason field is the input to the miss-reason word cloud and top-N panels in Track D. It is the only free-text content that travels to the collector — and it is content the user explicitly authored as feedback, not content the model produced or the user prompted with, so the no-content rule (which targets prompt/output text) does not apply.
- `delegate.feedback.parent_trace_id` and `delegate.feedback.parent_span_id` duplicate the `links` array as plain string attributes for backends that do not render `links` well in their default trace view. Backends that handle `links` correctly use the standard mechanism; backends that don't can still filter and join on the attribute. The fallback is intentionally redundant.

## What the exporter does NOT emit

Per ADR 0007's no-content rule, the following OTel-defined attributes are NEVER present in the payload, regardless of env-var settings:

- `gen_ai.prompt` (opt-in in the SemConv; unconditionally rejected here)
- `gen_ai.completion` (opt-in in the SemConv; unconditionally rejected here)
- Any `delegate.prompt_text`, `delegate.output_text`, `delegate.context_text`, or similar content-bearing attribute

Track F's redaction test (issue #158) is the tested invariant that backs this rule. It asserts that no attribute key matching these patterns is ever present in the OTLP body for any code path through the exporter. If a future change ever needs to emit content for a specific debugging workflow, the change has to update the test in lock-step, which forces an explicit decision rather than letting content leak in by accident.
