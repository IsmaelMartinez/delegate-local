# 16. Historical quality re-review

Date: 2026-06-18

## Status

Accepted.

## Context

Two flaws make the headline hit-rate a poor measure of delegation quality. The first, established in ADR 0015's 2026-06-18 update, is a labeling bias: inline verdicts the agent recorded about its own delegations were defaulting into the human tier, so the "human hit-rate" was largely the agent grading itself. The second is structural to the verdict itself: hit/miss is binary, and a "hit" means the agent *used* the output, not that the output was clean. A commit message used after the agent stripped a hallucinated PR number is recorded identically to one used verbatim. The hit-rate therefore counts "used after fixing" as success and overstates quality on both axes.

The natural next question is whether we can re-review past decisions to get a more honest number. The blocker is that the metrics never stored the model output or the source it should be faithful to — only character counts — so the delegations cannot be independently re-graded; the evidence is gone by design (outputs stay on-device and ephemeral). What the metrics do retain is the free-text `reason` attached to about 62% of verdicts: the reviewer's own note on why each was a hit or miss. That is a real, if partial, quality signal, and unlike the outputs it is on disk.

## Decision

`scripts/quality-report.sh` re-derives quality from the recorded reasons rather than trusting the binary verdict. It splits hits into "clean" (the reason says used verbatim / as-is) and "fixed" (the reason admits an edit, a stripped hallucination, a corrected fact), keeps misses as their own bucket, and reports a clean-as-is rate alongside the raw hit-rate. It re-reviews past decisions from data already present; it needs no live backend and no stored output.

It runs in two modes. The default is a keyword heuristic: zero dependency, instant, repeatable, but it leaves a large share of hits "ambiguous" because free-text reasons resist keyword rules — a floor, not a trusted number (on the current corpus it called only 51 of 271 reasoned hits clean, dumping 174 into ambiguous). The `--classify` mode delegates each reason to a local model for closed-form classification into CLEAN / FAITHFULNESS / PADDING / STRUCTURAL / STYLE / OPERATIONAL / OTHER. Classifying a short note into a fixed label set is exactly the closed-form task local models are reliable at (validated: a 30B coder model labelled a probe batch correctly and parseably), so `--classify` resolves the ambiguity the keyword mode cannot, while staying on-device and repeatable. It is slower — one local call per ~25 reasons — so it is opt-in rather than the default.

Three honesty boundaries are stated in the tool's own output. The reason is self-reported by the same agent that judged, so the problem counts are a lower bound and the clean-as-is rate an upper bound: a flaw the agent never noticed never became a reason, and those unnoticed faithfulness slips are exactly the bias the verdict cannot see. The 38% of verdicts that carry no reason cannot be re-reviewed and are reported as indeterminate rather than assumed good. And the failure-mode buckets, in either mode, are classifications of the note, not of the output, so they inherit whatever the note omitted.

## The reading (2026-06-18, `--classify` over 633 verdicts)

The raw hit-rate is 80% (509/633). Re-reviewing the 395 verdicts that carry a reason, 57% were clean (used as-is), 12% were used after a fix, and 31% were misses. So when there is evidence to judge, a clear majority of used outputs were genuinely clean — the picture is rougher than the 80% implies once "used after fixing" is separated out, but not the collapse the keyword floor suggested. Among the 171 problem cases (fixed-hits plus misses) the failure modes are padding 29%, structural 25%, faithfulness 23%, style 10%, and operational 9%. Faithfulness — hallucination or factual error, the "looks good but isn't" axis that no structural check can catch — is real and substantial but not dominant; formatting and structure together are the larger share, and those are what the recipes and the ADR 0014 deterministic checks already target.

## Consequences

There is now a repeatable, on-device way to re-review the verdict history and get a more honest number than the hit-rate, and it confirmed two things: the quality is meaningfully lower than the hit-rate once fixes are separated, and faithfulness is a real but minority failure mode. The limits are inherent: 38% of verdicts have no reason and stay indeterminate, and the signal is self-reported, so this measures admitted problems, not all problems. Closing those gaps is forward work that this re-review motivates rather than performs — persisting the deterministic `checks_failed` so future verdicts carry an objective structural companion (ADR 0014's signal is currently computed and discarded), the sampled Opus-subagent faithfulness audit chosen as the way to measure the one axis the reasons under-report, and, the cheapest lever of all, raising reason coverage above 62% so more of the history becomes re-reviewable in the first place.
