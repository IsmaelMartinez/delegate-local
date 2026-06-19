# 20. Verify-and-escalate gate, productionised

Date: 2026-06-18

## Status

Accepted. Productionises the prototype recorded in ADR 0019 (verify-and-escalate, PR #318) as an opt-in gate inside `scripts/delegate.sh`. Follows ADR 0018 (the fan-out negative result, PR #317), which is what redirected the quality work from sampling-ensembles to escalation in the first place. If 0018 and 0019 land under different numbers, renumber this in lock-step; the dependency is on the findings, not the integers.

## Context

The 2026-06-18 quality investigation put production miss rate at about 19.7%, with faithfulness roughly 23% of the problem cases (ADR 0016). ADR 0018 showed that sampling fan-out buys no quality on this backend because `mlx_lm.server` is deterministic per prompt and our failures are systematic rather than stochastic. ADR 0019 then prototyped the complement and found it works: run the task on a cheaper model, run the deterministic checks the wrapper already computes, and on a failed check escalate to a stronger model rather than re-prompting the small one. The prototype recovered the structured-output floors (T6 regex 0.50 to 1.00, T5 JSON 0.67 to 1.00) at a few seconds of added latency, paid only on failure.

This ADR records wiring that prototype into the production path so it can be switched on and benchmarked without changing the default behaviour of any existing caller.

## Decision

`delegate.sh` gains an escalation gate that runs after the deterministic checks and before the metrics emission. It is off by default and fires only when three conditions hold: the primary dispatch succeeded, a capability check failed on the primary output, and the caller named an escalation target that differs from the model the tier already resolved to.

The discrimination between which checks trigger escalation is the load-bearing design decision. A new counter, `capability_failed`, is incremented only by the checks a stronger model can plausibly clear — today `subject_max`, `subject_type`, and `body_required`. The one style check, `no_padding_tail`, never increments it: a padding tail is the ADR 0017 auto-strip's job, and ADR 0018's counterexample showed a stronger model reproduces the same padding (the 30B and 35B both pad the T4 body), so escalating on it would burn the strong model for nothing. New checks default to capability unless explicitly added to that style set, which is the safe bias — a check we forget to classify escalates rather than silently does nothing.

The escalation target is named by the caller, never hardcoded: `DELEGATE_ESCALATE_MODEL` pins an exact model and takes precedence; `DELEGATE_ESCALATE_TIER` resolves through `pick-model.sh` like any other tier. A tier that fails to resolve, or that resolves to the same model the primary used, leaves the gate inert. When the gate fires it re-issues the identical request to the target (no canary — the strong model is assumed reliable and the cost is bounded to one extra generation), re-runs the checks, and adopts the escalated output only if it fails strictly fewer capability checks. If it does not improve, or its dispatch fails, the primary output is restored untouched and the primary's success status is preserved. The model that produced the kept output is what the metrics row's `model` field records; `primary_model`, `escalated_to`, and `escalation_adopted` are added so the escalation chain is observable, and the `delegate-meta` stderr line surfaces the same.

Cost is asymmetric by construction. On the happy path the strong model is never loaded; it is paid for only when a capability check has already failed, which is exactly the case where the extra few seconds are justified.

## Verification

The mechanism is proven two ways. Twenty-seven unit assertions (in `tests/test-delegate.sh`, with a model-aware mock that returns a check-failing response for the primary and a passing one for the escalate target) cover adopt, reject-on-no-improvement, skip-on-style-only-failure, off-by-default, the same-model guard, fall-back when the escalation dispatch fails, and tier resolution. The full local suite stays green at 1630 assertions, and the off-by-default path produces a byte-identical metrics row to before, because the escalation fields are emitted only when the gate actually runs.

Live, with the 0.6B made the primary and the Coder-30B as the target on the real `commit-message` recipe: a docs-typo diff and a function-rename diff both had the 0.6B fail one capability check, escalated, and adopted a faithful, correctly-typed message (one to zero capability failures) at about 3.8 to 4.1 seconds total against roughly 1.8 seconds for the cheap-only path. The escalation metrics rows recorded `primary_model` as the 0.6B and `model` as the kept 30B, exactly as designed.

## Consequences and honest boundaries

The gate is a safety net, not a substitute for routing the right model in the first place, and the live run made that boundary vivid. On a third diff the 0.6B regurgitated a recent-commit example from its context verbatim — a faithfulness failure — but the output was structurally clean, so `capability_failed` was zero and the gate correctly did not fire and could not have helped. Faithfulness, the dominant remaining miss bucket, is invisible to structural checks; the lever for it is capability-matched primary routing (do not send `commit-message` to a 0.6B), not escalation. The gate addresses the capability bucket and leaves the faithfulness bucket where ADR 0016 left it.

Two further limits are worth stating so they are not rediscovered. `subject_type` is a noisy capability signal: a stronger model may deliberately pick a more appropriate conventional-commit type than the caller asserted and be counted as failing for it; the gate treats that as capability (it enforces the caller's stated intent) but the signal is not clean. And the recipes where the prototype showed the largest gains — the structured-output ones (JSON extraction, regex) — do not yet declare capability checks, so the gate rarely fires there today. Adding structured capability checks (a valid-JSON check, an anchored-regex check) so those recipes can benefit is the named next lever, deferred to keep this change focused on the mechanism. The gate also inherits the checks' gating and does not run when `DELEGATE_LOCAL_NO_META=1` disables them.
