# 11. Contrastive Wrong/Correct anchors — asymmetric Correct form for participial vs declarative shapes

Date: 2026-05-24

## Status

Accepted.

## Context

Phase 13 closed with the empirical observation that directive-text enumeration on `prompts/commit-message.md` had reached a saturation point under greedy decoding on `qwen3.6:35b-a3b-q8_0`. Adding more forbidden-phrase examples to the directive enumeration was no longer the right lever — the model would AVOID each enumerated phrase on the next round, then default to a structurally-equivalent unenumerated phrase that the directive had not yet named. The Phase 13 ROADMAP entry named the next-iteration candidate as either a Wrong/Correct contrastive sharpening or a different structural lever. The user's auto-memory at `feedback_directive_binding_ceiling.md` records the saturation finding as "Directive-binding ceiling on enumeration text — adding more forbidden-phrase examples has a ceiling under greedy; next iteration needs a different lever".

Phase 15 Track A measured the contrastive-anchor lever empirically against the T4 fixture. Baseline against the prior `prompts/commit-message.md` template (preserved as `task-4-commit-message-2026-05-24-pre-phase-15.txt`, three reps, prose tier) confirmed the ceiling at `12/18 cumulative, mean 0.67`, with every rep failing both SUBJECT_LEN (subject 77 chars) and BODY_NO_PADDING (the model emitted `, providing X` and `, allowing X` participial tails despite both verbs being literally named in the directive enumeration). The intervention expanded a single closes-the-gap Wrong/Correct anchor into four pairs covering the participial-`, providing` shape, the participial-`, allowing` shape, the declarative-`This ensures` shape, and the original closes-the-gap form. Post-edit re-measurement against the new fixture scored `18/18 cumulative, mean 1.00`, with both SUBJECT_LEN (50-char subject) and BODY_NO_PADDING now passing.

The PR review surfaced the load-bearing iteration. The original Phase 15 Track A edit used a parenthetical Correct form for the two declarative-padding pairs — `(sentence ends after the substantive content; no This-X restating tail at all.)` for the `This ensures` shape and `(sentence ends after the substantive content; no closes/closing-the-gap or -loop tail at all.)` for the closes-the-gap shape. The gemini-code-assist bot reasonably flagged this as a content-leakage risk: meta-descriptions in the Correct field of a contrastive anchor can prompt the model to literally include the parenthetical text in its output, especially under greedy decoding on smaller models. The bot suggested concrete-sentence variants for both declarative pairs, mirroring the participial pairs (`Correct: The rate limiter and cache stay in sync.` instead of the parenthetical).

The empirical iteration in commit `7ddc1f5` applied the bot's suggestion and re-measured T4 against the same fixture and anchors. The result REGRESSED to `15/18 cumulative, mean 0.83`, with three of three reps failing BODY_NO_PADDING on `, allowing direct comparison…` participial tails — despite the explicit `, allowing` Wrong/Correct anchor still sitting in the recipe above. Reverting the two declarative pairs to the parenthetical form restored 18/18. The bot's concrete-sentence variant was empirically worse on this fixture even though the variant was the safer choice on first principles.

## Decision

The contrastive Wrong/Correct anchor pattern uses an asymmetric Correct form keyed off the structural shape of the Wrong content:

For participial-tail Wrong content (`, providing X`, `, allowing Y`), the Correct form is a concrete-rephrased version of the same Wrong sentence with the participial clause replaced by a coordinate clause or a substantive verb. Example pair from `prompts/commit-message.md`:

```
Wrong: The endpoint validates JSON inputs, providing structured error responses on failure.
Correct: The endpoint validates JSON inputs and returns structured error responses on failure.
```

The Correct form here works because the participial-tail content is genuinely salvageable by rephrase — the original sentence contains two facts (the endpoint validates, the endpoint returns errors) and the Correct form preserves both, just expressed without the participial structure the directive forbids. The model has a concrete imitation target: take the same factual content and re-express it without the forbidden shape.

For declarative-restating Wrong content (`This ensures X`, `This closes the gap`), the Correct form is a parenthetical meta-description naming what the restating tail should be replaced with — concretely, with nothing. Example pair from the same recipe:

```
Wrong: This ensures the rate limiter and the cache invalidator stay in sync.
Correct: (sentence ends after the substantive content; no This-X restating tail at all.)
```

The asymmetry is the load-bearing finding. Declarative restating tails do NOT add new factual content — `This ensures X` simply restates the consequence of the preceding sentence. A concrete Correct form would have to invent the substantive content the Wrong form was restating against, which is exactly the leakage risk the parenthetical form avoids. The parenthetical Correct form reinforces the abstract rule (`no This-X restating tail at all`) in addition to demonstrating it; the concrete-sentence variant loses that abstract reinforcement and the model defaults to participial-tail shapes on different verbs.

The 18/18 → 15/18 → 18/18 measurement sequence is the empirical evidence for the asymmetry. The first round (parenthetical Correct for declaratives) scored 18/18 with zero content leakage observed across the three reps — the meta-description risk gemini-code-assist flagged was theoretical on this fixture under greedy decoding. The second round (concrete Correct sentences for declaratives, the bot's suggestion) regressed to 15/18 with the participial-tail failure surfacing on `, allowing direct comparison…` despite the participial anchor still binding the original verbs. The third round (revert to parenthetical Correct for declaratives, keep concrete Correct for participials) restored 18/18. The asymmetry was the difference between the two non-regression states; the structural shape of the Wrong content determined whether the Correct form should be concrete or parenthetical.

Phase 15 Track C documents the asymmetry as `prompts/README.md` Convention 3 with the two recipe-authoring rules drawn from the measurement: domain-neutral Correct examples (the first iteration used recipe-adjacent phrasing about fixtures and anti-padding and the model copied the Correct sentence verbatim into the body because it was on-topic), and the asymmetric Correct form discipline keyed off Wrong-content shape (concrete-rephrased for participial-tail Wrong, parenthetical meta-description for declarative-restating Wrong).

Phase 15 shipped via PR [#208](https://github.com/IsmaelMartinez/delegate-local/pull/208) (squash `81c3d68`, merged 2026-05-24).

## Consequences

Recipes whose directive enumeration is saturating have a measurable next-lever to reach for: promote a single Wrong/Correct pair to multiple pairs covering the structural shape families, with the Correct-form discipline keyed off the Wrong content's structure. The lever is empirically validated past the directive-binding ceiling on T4; the lever's effectiveness on other recipes is not yet measured but the convention codification in `prompts/README.md` Convention 3 makes the order-of-operations (contrastive anchors first, call-site reinforcement second, structural scorer extension third, tier escalation only after empirical per-recipe measurement) the default starting point for a recipe whose enumeration has stopped binding.

The asymmetric Correct form is the central insight worth carrying forward. Future recipe authors hitting the directive-binding ceiling will instinctively reach for concrete Correct sentences across all shapes because the concrete form is the safer default on first principles (no meta-description leakage risk, no abstract-reinforcement coupling to model behaviour). The Phase 15 measurement sequence demonstrates that the safe default is not always the empirical best — the parenthetical Correct form scored 18/18 where the concrete form scored 15/18, and the difference traces to whether the Wrong content carries salvageable factual content (participial-tail, yes) or pure restating with no new fact (declarative, no). Recipe authors who skip this asymmetry will likely regress recipes that previously calibrated well, because their concrete Correct sentences for declarative-restating Wrong content will leak the substantive content the parenthetical form deliberately withholds.

Phase 15 Track A's caveat is worth carrying forward as the next-iteration prediction. One of the three post-edit reps emitted `, replacing assertion with data` — a participial-tail shape whose verb (`replacing`) is not in the scorer's `PADDING_REGEXES` enumeration. The model now AVOIDS the enumerated verbs but defaults to a structurally-equivalent unenumerated verb. Verb-level enumeration has succeeded on coverage, but the underlying participial-tail STRUCTURE persists. The next-iteration candidates named in `prompts/README.md` Convention 3 are extending the scorer's regex set with the next batch of unenumerated verbs (Phase 16 Track B did this for `replacing`, `supporting`, `reflecting`, `keeping`, `exemplified`, and `This provides`, then measured that the model substituted ANOTHER unenumerated verb set on the same fixture — the verb-substitution treadmill confirmed empirically), or attempting a generalised `, [a-z]+ing` trailing-clause matcher with calibrated false-positive thresholds. The Phase 16 measurement positions the structural matcher as the highest-leverage open lever.

What would justify revisiting the decision: a Wrong content shape that is neither participial-tail nor declarative-restating but exhibits a third structural pattern where neither concrete nor parenthetical Correct form binds well; a measurement on a different recipe (presentation-slide-prose, doc-section, polish-reply) showing the asymmetry rule reverses on that recipe's calibration axis; or a model class (a new Qwen3 release, a different model family) where the parenthetical Correct form starts leaking the meta-description text into outputs at meaningful rates. The first justifies extending the convention to a third shape family; the second justifies a per-recipe override on the asymmetry rule; the third justifies reverting to concrete Correct forms across the board and accepting the directive-binding ceiling regression on declarative-restating shapes as the cost.

The cost of this ADR is one more file in `docs/adr/`. The benefit is that the empirical 18/18 → 15/18 → 18/18 measurement sequence, the asymmetric Correct-form rule it justifies, and the structural reasoning behind why participial-tail Wrong content has salvageable factual content while declarative-restating Wrong content does not, now live in a durable single artifact. A future contributor who reads `prompts/README.md` Convention 3 and wonders why the Correct form is asymmetric finds the measurement here rather than only as a one-line caveat in the Phase 15 ROADMAP entry.
