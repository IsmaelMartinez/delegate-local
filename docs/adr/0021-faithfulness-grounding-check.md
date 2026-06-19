# 21. Faithfulness grounding check

Date: 2026-06-19

## Status

Accepted as a measured prototype tool (`scripts/grounding-check.sh`) with a unit suite. Wiring it into `delegate.sh` as an opt-in `grounding` check is the documented follow-on (it depends on, and composes with, the ADR 0020 escalation gate, PR #319). Builds on ADR 0016 (the quality re-review that sized the faithfulness bucket) and ADR 0020 (which explicitly left faithfulness out of the gate's reach).

## Context

ADR 0020 recovered capability failures but stated plainly that it cannot touch faithfulness — a structurally clean answer that is semantically wrong is invisible to the deterministic checks, and faithfulness is the dominant remaining miss bucket (~23%, ADR 0016). The live evidence was vivid: a 0.6B produced a perfectly well-formed commit message about a "stale lock file / daemon crash" for a diff that was actually about account lockout, and because it was structurally clean the gate correctly did not fire.

This ADR records a deterministic lever for the GROSS subset of faithfulness failures — whole-topic drift and context regurgitation — and, importantly, measures it before recommending production wiring, because a faithfulness check has a real false-positive risk (a terse-but-faithful commit may legitimately name no code symbol).

## Mechanism

`grounding-check.sh` takes the INPUT (a unified diff or other source context) and the model OUTPUT and asks one question: does the output mention at least one distinctive identifier that actually appears in the input? It extracts identifiers from the diff's changed lines and file paths, then checks whether the output cites any of them (lenient, case-insensitive substring match — `auth` grounds `authentication`). An output that cites none is flagged UNGROUNDED.

The load-bearing refinement is the notion of a DISTINCTIVE identifier. The naive version false-passed the canonical regurgitation: the drifted output said "lock file," the diff's intent comment said "lock account," and the shared common word "lock" was enough to ground it. The fix: a lone generic short word is not evidence. An identifier counts as distinctive only if it looks like a code symbol the model could not have produced by chance — it contains an underscore, contains an uppercase letter (camelCase / PascalCase / CONSTANT), or is long (≥7 chars); a filename-derived token counts at ≥4 chars. The output is grounded if it cites at least one distinctive identifier, or at least two identifiers of any kind (two independent coincidences being unlikely). When the input carries fewer than three distinctive identifiers (a trivial or whitespace-only diff) the check returns SKIP rather than risk a false positive on a diff that cannot ground anything. Matching is deliberately lenient and the bar for flagging is deliberately high, because the one thing the check must never do is punish a faithful answer.

## Measurement

Six diffs, each run through the `commit-message` recipe on both a deliberately weak primary (Qwen3-0.6B) and a strong one (Qwen3-Coder-30B), then scored. The full outputs are in `experiments/results/2026-06-19-grounding-check.md`.

The weak model was not merely imperfect, it was catastrophically unfaithful: all six 0.6B outputs ignored the diff entirely and regurgitated unrelated content from the recipe's own context window (three repeats of a "stale lock file" message, three of a "#315 quality-report" commit). The grounding check flagged five of the six as UNGROUNDED. The one it missed had a subject line that coincidentally named the changed file while its body was pure regurgitation — a partial-drift false negative, the expected blind spot. The strong model was faithful on all six, and the check flagged none of them.

That is 100% precision (every UNGROUNDED flag was a genuine drift; zero false alarms on faithful output) and 83% recall (five of six gross drifts caught) on this set. The precision number is the one that matters for safety: the check did not punish a single faithful answer.

## The honest impact estimate

The improvement this buys depends entirely on which model is the primary, and it would be dishonest to quote a single headline number without that caveat.

On today's default routing — `pick-model.sh` already selects the strongest installed model per tier — the expected improvement to the production miss rate is small, on the order of a couple of points at most and probably less. The strong models rarely grossly drift (zero of six here), and the faithfulness misses they do produce are subtle (the right identifiers present, a wrong claim about them) which a grounding check cannot see. The ~19.7% production miss rate will not move much from this lever alone on the strong default.

The real value is forward-looking: the grounding check is what makes a cheap-first default viable. The 0.6B's regurgitations are structurally clean, so the ADR 0020 gate alone would never escalate them (their capability-failure count is zero). Adding grounding as a capability check makes that drift visible, so the gate escalates the ungrounded output to the faithful strong model. Cheap-first faithfulness on this task therefore moves from roughly nil (six of six garbage, silently kept) to roughly 83% recovered at 100% precision — and that, not a shift in the strong-default number, is what unlocks "default to the small fast model, pay for the big one only when the small one drifts."

## Decision and follow-on

Ship `grounding-check.sh` and its tests now as a self-contained, measured tool. The wiring — a `grounding` case in `run_output_checks` that compares `$output` against the gathered `$context`, classified as a capability check so the gate escalates on it, plus `grounding: true` added to `commit-message.md` — is the next step, stacked on the gate (PR #319) because it both depends on the gate's `capability_failed` plumbing and changes a production recipe's behaviour. The measurement in this ADR is the evidence that justifies that change; without the 100%-precision result it would have been speculative.

## Limits

The check sees gross topic-drift, not subtle wrong-detail faithfulness failures, so it is a recall floor for the faithfulness bucket, not a solution to it. It depends on the input carrying distinctive identifiers, so it is strong for diffs and code-shaped inputs and weak-to-inapplicable for free-prose summarisation recipes (which is why it must be opt-in per recipe, not global). And the subject-only-grounding false negative is real: an output whose subject names a file but whose body is invented will pass. None of these undercut the core result — a zero-false-positive, 83%-recall floor on the gross faithfulness failures that a cheap-first default would otherwise ship silently.
