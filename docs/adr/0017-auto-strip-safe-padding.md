# 17. Auto-strip safe padding tails, and persist the check results

Date: 2026-06-18

## Status

Accepted. Amends ADR 0014 (deterministic output-constraint checks).

## Context

ADR 0014 shipped the deterministic output checks as warn-only, deferring any auto-fix on the grounds that "greedy decoding makes a naive re-roll fruitless" and "auto-correction is neither free nor obviously safe." Two findings since then change that calculus for one specific check.

First, the 2026-06-18 quality re-review (ADR 0016) measured where delegated output actually falls short. Of the documented problem cases, padding is the single largest bucket (29%), and structural is next (25%) — together more than half. Padding is also the failure the warn-only design leaves the agent to hand-strip on every occurrence, which is exactly what shows up in the metrics as "used-after-fixing" rework rather than clean output. The check detects it deterministically but then does nothing with that detection.

Second, the most common padding shape is narrowly and safely fixable in a way the general auto-correction ADR 0014 ruled out is not. The recurring offender is a trailing participial clause — "…, ensuring backward compatibility", "…, confirming the need for a matcher" — which the check targets precisely because it restates the point and carries no new content. Removing a clause that is filler by the check's own definition is a deterministic deletion, not a re-generation, and not the open-ended rewrite ADR 0014 was right to avoid.

Separately, the `checks_failed` count ADR 0014 surfaced on the stderr meta line was never persisted to the metrics JSONL, so structural quality has been unobservable in the data — you could see a single run's warning but never measure the rate across production.

## Decision

Two changes, both in `delegate.sh`'s post-generation check block.

The check results are now persisted. Each delegation that runs at least one check writes `checks_run`, `checks_failed`, and `checks_autofixed` to its metrics row (omitted entirely when no checks ran, so non-recipe and no-check rows are unchanged). Structural quality is now a queryable production signal, not an ephemeral stderr line.

The `no_padding_tail` check auto-strips the safe shape. Detection stays broad — any `", <gerund>"` tail — so recall on the warning is unchanged. The strip is deliberately narrower for precision: it fires only on a trailing `", <filler-gerund> …"` clause where the gerund is one of a focused filler-verb allowlist (ensuring, allowing, enabling, leading, reflecting, making, and similar meta-verbs), there is sentence content before the comma, and the clause runs to the end of the line with no internal comma. The allowlist is what keeps the mutation from deleting a meaningful participial like "…, preserving insertion order" — a verb outside the list is detected and left as a `FAILED` warning for the reviewer, never silently removed. The strip is then adopted only when the result is non-empty (a failed `perl` returns nothing, which is never shipped) and actually clears the padding; otherwise the original output is kept untouched, so a `FAILED` verdict always corresponds to the emitted text. The riskier "This-X" / "in summary" restating shapes are never auto-stripped. A successful strip is reported as `AUTO-FIXED` on stderr, counted as `checks_autofixed` (not `checks_failed`), and surfaced on the meta line. So `checks_failed` now means "problems shipped" and `checks_autofixed` means "problems fixed in place." The behaviour is on by default — this is the quality improvement — with `DELEGATE_NO_AUTOFIX=1` to restore strict warn-only.

Four properties bound the silent-over-strip risk that justified ADR 0014's warn-only caution. The shape is conservative (single trailing gerund clause, no internal comma, content required before it), so the ambiguous cases that could carry meaning are refused, not stripped. Every strip is recorded (`checks_autofixed` on the meta line and in metrics), so it is auditable rather than silent. The agent's mandatory verify step still runs on the final output. And the escape hatch restores the old behaviour for anyone who wants detection without mutation.

## Consequences

The largest documented failure bucket converts from per-occurrence hand-fixing to clean-by-default output, which both improves the delegated result and removes the rework that inflated the "fixed hit" share in ADR 0016's reading. Structural quality becomes observable in the metrics for the first time, so the effect of this change — and of any future recipe or model change — can be measured rather than asserted (the `checks_failed` rate over recipe delegations is the number to watch). The conservative shape plus the recording plus the verify step plus the opt-out are what make reversing ADR 0014's default defensible for this one check without reopening the general auto-correction question.

Deliberately still out of scope: perturbed re-roll / regeneration (the second-call cost and non-determinism ADR 0014 named remain real), auto-fixing the structural checks (subject length, stray `(#NN)` — these are not safe deletions), the "This-X" padding shape (sentence-level, not a clause deletion), and faithfulness, which no deterministic transform can address and which the sampled-audit work owns.
