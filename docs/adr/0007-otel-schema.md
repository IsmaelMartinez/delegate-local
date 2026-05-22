# 7. OpenTelemetry export schema — namespace split, feedback-as-linked-span, no content attributes

Date: 2026-05-22

## Status

Accepted.

## Context

Phase 11 of the ROADMAP extends the on-disk JSONL telemetry that Phase 8 introduced out to an external OpenTelemetry backend, so that hit-rate, miss-reason distribution, and tokens-avoided rollups live in a real observability tool rather than only behind `metrics-summary.sh`. The exporter is filed as issue [#134](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/134) (Track A). This ADR (Track B, issue [#154](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/154)) lands the schema decisions Track A encodes, so Track A's review has a written reference to check the wire payload against rather than having to re-derive the rationale during code review.

Three decisions need a durable artifact because each has at least one rejected alternative whose drawbacks are not obvious without the supporting research. The 2026-05-21 planning sweep cited in ROADMAP Phase 11 surfaced the relevant OTel SemConv state (`gen_ai.*` attributes still in Development status; no Stable attribute or metric yet; `ollama` and `mlx` already registered as `gen_ai.provider.name` values; the `gen_ai.client.operation.duration` histogram is what the Grafana Cloud GenAI dashboards key off) and the relevant external prior art (Langfuse's `scores` API models user feedback as a first-class object keyed by `traceId`; OTel's documented span-links pattern covers the human-in-the-loop case where feedback can arrive long after the parent trace is flushed). The skill stays "two bash scripts" throughout — `jq` plus `curl`, no Python or Go SDK runtime dependency — and content never leaves the host. The schema has to be consistent with both constraints.

## Decision

### Namespace split: `gen_ai.*` for upstream-conventional concepts; `delegate.*` for everything else

Attributes that map cleanly onto an existing OTel GenAI semantic convention use the convention's attribute name verbatim. That covers `gen_ai.operation.name`, `gen_ai.provider.name` (set to `ollama` or `mlx`, both already registered as provider strings in the SemConv registry), `gen_ai.request.model`, `gen_ai.request.temperature`, and — when Track G ships the metrics counter — the `gen_ai.client.operation.duration` histogram. Grafana Cloud's pre-built GenAI dashboards key off these names, so following the convention is what unlocks the zero-config dashboard import that ROADMAP Phase 11 calls out as the default platform recommendation.

Attributes the WG does not cover — verdict (`hit`/`miss`), recipe name, tokens-avoided estimate, the four char-count fields, exit_status, and tier — go under a private `delegate.*` prefix. This follows the OTel SemConv guidance that vendors and applications use a custom namespace prefix for fields outside the canonical conventions.

The rejected alternative is squatting on plausible-looking but currently unreserved names inside `gen_ai.*` — concretely, putting verdict at `gen_ai.evaluation.verdict` or recipe at `gen_ai.prompt.recipe`. The drawback is future-collision: the WG is actively iterating on the GenAI conventions (everything is still in Development status), and if a real `gen_ai.evaluation.*` namespace is later promoted to Stable with semantics that don't match this skill's verdict shape, the attribute either silently changes meaning to consumers or has to be migrated on a breaking-change schedule the project does not control. Confining all skill-specific attributes to `delegate.*` makes the namespace boundary explicit and avoids the migration.

### Feedback span is a NEW trace whose `links` point back to the parent — not a parent-span event, not trace reuse

`scripts/delegate.sh` emits one span per invocation at delegation time. `scripts/delegate-feedback.sh` runs later — often minutes, sometimes hours after the parent delegation, because the verdict is recorded once the agent has had a chance to use or reject the output. When the feedback fires, the parent trace has already been closed by the exporter and flushed to the collector. Three encoding options exist; this ADR picks the third.

The first option is to mutate the parent span by appending a span event for the verdict. Rejected because span events are part of the span's payload and the span has already been finalised and sent — adding an event would require either re-opening a closed span (which OTel does not support) or buffering the parent span locally until the feedback arrives (which defeats the purpose of immediate export and breaks if the agent is restarted between delegation and feedback). The skill stays "two bash scripts" and cannot run a long-lived buffer process.

The second option is to reuse the parent's trace ID and emit the feedback as a sibling span inside the same trace. Rejected because trace-level operations in OTel backends (sampling, retention, completeness checks) assume the trace is complete when its root span ends. A late sibling arriving hours after the root closes is typically dropped by the collector's trace-completeness logic, or stored but rendered as an orphan that the trace view doesn't reliably show.

The chosen option is to emit the feedback as a new short span in a new trace, with the parent's trace ID and span ID carried in the feedback span's `links` array (`links: [{traceId, spanId}]`). OTel's documented span-links pattern (https://opentelemetry.io/docs/languages/dotnet/traces/links-creation/) covers exactly this case: a span that is causally related to one in a different trace, where the causal relationship is real but the timing is decoupled. Langfuse's `scores` API (https://langfuse.com/docs/observability/features/user-feedback) is the parallel prior art outside OTel — it models user feedback as a first-class object keyed by `traceId` rather than mutating a closed parent, because the two events are temporally separate by design.

To make the link discoverable even on collectors and backends that do not render `links` well, the feedback span also carries `delegate.feedback.parent_trace_id` and `delegate.feedback.parent_span_id` as plain string attributes. This is belt-and-braces — backends that handle `links` correctly will use the standard mechanism; backends that don't will at least let the user filter and join by attribute. The parent IDs themselves are captured into the JSONL row at delegation time (`otel_trace_id`, `otel_span_id`) so the feedback script can correlate without a second lookup, and so historical backfill (Track E) can reconstruct the link for rows that pre-date the exporter.

### No prompt or output content as attributes — char counts only

The skill's README and SKILL.md frontmatter both frame on-device privacy as a primary value: content stays on the host, only routing metadata travels. The wire payload to the OTel collector must match that framing, regardless of which backend the user points the exporter at.

The exporter therefore emits character counts (`delegate.prompt_chars`, `delegate.context_chars`, `delegate.output_chars`) but never the prompt, context, or output text itself. The OTel GenAI conventions reserve `gen_ai.prompt` and `gen_ai.completion` as opt-in content attributes (they are explicitly off-by-default in the SemConv); this skill rejects those attributes unconditionally rather than gating them behind a flag.

The rejected alternative is a flag like `DELEGATE_OTEL_INCLUDE_CONTENT=1`. Drawback: a flag invites the failure mode where a user enables it for a debug session, forgets it on for the next privacy-sensitive workload, and ships prompts to a third-party collector. Track F (issue #158) adds a unit-test assertion that no attribute key matching the content patterns is ever present in the OTLP body, regardless of env-var settings, which makes the no-content rule a tested invariant rather than a documented convention.

## Consequences

The wire payload is fully enumerated by `docs/otel-schema.md` (the companion to this ADR), which lists every attribute with its source JSONL field, OTel convention reference, and example value. Track A's review checks the exporter's payload against that table directly. Track F's privacy-redaction test treats the no-content rule as a tested invariant.

The namespace split makes future-collision with WG-promoted attribute names a non-issue for any skill-specific field. If the WG ever ships a `gen_ai.evaluation.*` namespace, this skill can decide separately whether to mirror its verdict attribute into the new namespace alongside the existing `delegate.feedback.verdict` (with a deprecation period for the private name) or stay private — the migration is cheap because the private name was never claimed to be canonical.

The feedback-as-linked-span pattern means feedback events show up in the observability backend as their own trace, joined to the parent delegation either by `links` (standard mechanism) or by `delegate.feedback.parent_trace_id` (fallback for backends that don't render links). Dashboards (Track D) consume the join in whichever form their backend supports.

The no-content rule means dashboards cannot show the prompt text alongside the output for debugging. Acceptable trade-off: the calibration history already lives in `metrics.jsonl` plus the per-recipe `Calibration notes` in `prompts/<task>.md`, which both stay on-host. Anything that needs prompt-level introspection uses the local files directly.

What would justify revisiting any of the three decisions: the WG promoting `gen_ai.*` evaluation conventions to Stable with semantics that match the verdict shape (re-open the namespace split for the verdict attribute specifically); a real observability backend with documented and dependable `links` rendering becoming dominant enough that the parent-id fallback attributes are dead weight (drop the fallback); or a use case where on-device debugging genuinely needs prompt content in the dashboard and the user explicitly accepts the privacy trade-off (still likely better solved by a local-only Phoenix instance than by relaxing the no-content rule).

The cost of this ADR is one more file in `docs/adr/` plus the companion reference doc. The benefit is that Track A's code review references the schema decisions directly rather than re-deriving them, and any future contributor who wonders why the exporter looks the way it does finds the rationale in one place.
