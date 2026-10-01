# Calibration history for [`prompts/summarise-issue.md`](../../prompts/summarise-issue.md)

## Calibration notes

Initial recipe drafted 2026-05-10 from the `cat build.log | delegate.sh reasoning "List only the lines indicating test failures."` example in SKILL.md's Pattern section. The recipe generalises that example: SKILL.md's snippet is a closed-form filter over a single log file; this recipe handles the broader "long thread → timeline" shape that requires the same citation-rate discipline.

### 2026-05-10 dogfood: HIT-with-edits — OMIT rule resists three iterations

Three consecutive attempts against `deepseek-r1:32b` (reasoning tier) on issue #75 (~3 KB input). All three placed a "No blockers explicitly stated in the thread" bullet under `## What's blocking` despite progressively stronger rules:

1. Soft "OMIT this section entirely. Do NOT speculate" — produced placeholder.
2. Named "OMIT-EMPTY-SECTION RULE" with explicit "the entire heading line MUST NOT appear ... no placeholder bullets like 'No blockers'" — still produced placeholder.
3. v5/v7-style directive-rule with priority + Wrong/Correct contrastive example showing the heading absent — still produced placeholder.

The other content was correct on all three runs: `## What happened` bullets cited dates, `## What's next` bullets matched the issue's stated fix options, no fabrication. The only resistant failure mode is the empty-section placeholder.

Useful empirical finding: the v5/v7 directive-rule + contrastive-example pattern that closed the severity-capping gap (5/5 Opus parity on the same model) does NOT fully bind on this task shape. Hypothesis: the model interprets "explicit empty marker" as compliant with the rule because it is being honest about absence, not fabricating presence. The Phase 10 retrospective's "directive-rule with hard-coded keyword triggers" pattern was tested against closed-form classification, not output-structure conditional rules; the latter may need a different discipline (perhaps a string-level prohibition like "your output must not contain the substring 'No blockers'").

Recipe ships with HIT-with-edits status: the output is usable after deleting "No X stated" placeholder lines by hand.

### 2026-05-11 — string-level prohibition also fails to bind

Fourth attempt with the explicit substring prohibition gemini-code-assist suggested on PR #81 (and which the calibration note above hypothesised would work): the rule was extended to `Your output MUST NOT contain the substrings "No blockers", "no blockers", "no specific blockers", "Nothing to do", "TBD", "N/A", or any other phrase indicating absence`. Re-tested against the same issue #75 on `deepseek-r1:32b` (reasoning tier).

Result: the model produced `## What's blocking\n- No explicit blockers stated in the thread.` — an unlisted synonym for the prohibited set. The "or any other phrase indicating absence" catch-all did not bind either.

This is a sharper empirical finding than the previous iteration. The model is not just ignoring a directive; it is actively pattern-matching for unlisted synonyms when its preferred behaviour (explicit-absence-marker) is forbidden. The world-model is "honest acknowledgement of absence is informative output", and prompt-only calibration up to and including substring blocklists cannot override that on this task shape on this model.

Concrete next options for a future calibration iteration:
1. Restructure the template so optional sections are described as conditional-include rather than conditional-omit (positive rule, not negative).
2. Route to a different tier (the `code` tier with `qwen3-coder-next:latest` may bind the rule differently; the v6 retro found same-family scale-down loses cross-reference capability, but the cross-reference being lost here is about output structure, not severity calibration).
3. Add a post-processing step in the recipe documentation: `sed -i '/^- No .* stated.*$/d; /^## What.s blocking$/d' <<< output` as a known artefact strip.
4. Accept the placeholder as a HIT-with-edits artefact and let users strip by hand (current state).

Option 1 or 2 are the empirical experiments worth running next.

### 2026-05-22 — positive-form OMIT directive + Comment-N citation guard (issue #148)

Issue #148 documented two failure modes observed on 2026-05-21 against `deepseek-r1:32b` (reasoning tier) summarising issue #134 (zero comments at the time of the delegation `2026-05-21T16:46:09Z`):

1. **OMIT-EMPTY-SECTION bypass.** The model produced `## What's blocking\n- No explicit blockers stated in the thread.` — a paraphrase that the substring blocklist did not literally enumerate. The "or any other phrase indicating absence" catch-all from the 2026-05-11 iteration did not bind. Same compliance-literally-with-the-rule-it-knows pattern that the commit-message recipe's enumeration-extension iterations were filed against.
2. **Comment-N hallucination on zero-comment input.** Verbatim model output:

   ```
   ## What happened
   - 2026-05-20: User raised the idea of integrating OpenTelemetry for better observability.
   - Comment-1: Implementation plan outlined, including opt-in OTLP exporter alongside JSONL.
   - Comment-2: Discussed emitting one span per `delegate.sh` invocation with specific attributes.
   - Comment-3: Mentioned adding a counter metric and handling feedback verdicts via spans or events.
   - Comment-4: Decided to keep JSONL as the primary data source, not replacing it.
   ```

   Issue #134's `comments:` array was empty at delegation time; the model conflated the body's internal markdown section headings (`## Context`, `## Scope`, `## Implementation plan`, etc.) with separate comment entries. The recipe had no guard against this shape.

The fixes follow the calibration-iteration discipline established by the commit-message recipe's `(#NN)` and declarative-rephrase iterations:

- **Fix 1 (OMIT-EMPTY-SECTION).** Took option 1 from the 2026-05-11 calibration entry's next-options list. The prompt's OMIT rule was recast from a negative substring blocklist into a positive conditional-include directive: include the `## What's blocking` heading ONLY if the input contains an explicit blocker statement. The test was made semantic ("the sentence's meaning is the input does not contain a blocker") rather than literal-substring, so paraphrases like `No explicit blockers stated` and `None mentioned` are caught by the directive itself rather than by enumerating their exact wording. The substring blocklist is retained inside the parenthetical as a belt-and-braces secondary guard. Contrastive Wrong/Correct anchors cover BOTH the zero-comments thread shape (the actual issue #148 failure) AND a with-comments thread shape (so the model doesn't over-generalise to either case) per the PR #173 review principle that few-shot examples must anchor both outcomes.
- **Fix 2 (COMMENT-N-CITATION).** A new priority-2 directive states explicitly that `comment-N` indexes the `comments:` array of the input, that body markdown headings are body structure not comments, and gives the correct citation form for body facts ("the issue body" or "the body's '## Heading' section"). Wrong/Correct anchors pair a zero-comment case (the actual #148 failure shape) with a with-comments case where a body heading must still be cited as body, not as `Comment-(N+1)` — same anchor-both-outcomes discipline.

Same v5/v7 directive-rule-plus-Wrong/Correct-one-shot pattern that closed the commit-message recipe's `(#NN)` gap on PR #75 and the declarative-rephrase gap on PR #86. Applied here to output-structure conditional rules — the task shape the 2026-05-11 calibration entry flagged as resistant to substring blocklists. The empirical question this iteration tests is whether the positive-form conditional-include phrasing flips the rule from advisory to binding, where the negative-form substring blocklist did not.

**Dogfood result (delegation ts=2026-05-22T11:11:53Z, `deepseek-r1:32b`, issue #159 with zero comments, ~1 KB input): MISS on BOTH failure modes.** Verbatim model output reproduced the exact two pathologies the iteration was filed against — `## What's blocking\n- No explicit blockers stated in the thread.` (positive-form directive bypassed by the same paraphrase that bypassed the substring blocklist on 2026-05-21) and `Comment-1` through `Comment-5` referring to body markdown sections on a zero-comment issue (the COMMENT-N-CITATION directive did not bind either). MISS recorded against ts=2026-05-22T11:11:53Z with reason naming both failures.

This is a sharper version of the 2026-05-11 finding: directive-form is not the discriminating axis on this task shape on this model. Both substring-blocklist and positive-form conditional-include leave `deepseek-r1:32b` emitting the same "honest acknowledgement of absence" sentence, regardless of phrasing strength. The 2026-05-22 dogfood empirically rules out option 1 from the 2026-05-11 next-options list as a prompt-only fix.

Concrete next options (refined from the 2026-05-11 list given the new MISS evidence):
1. ~~Restructure as positive-form conditional-include.~~ Empirically falsified 2026-05-22.
2. Route to a different tier — the `code` tier with `qwen3-coder-next:latest` or the `prose` tier with `qwen3.6:35b-a3b-q8_0` may bind the conditional-omit rule differently. The 2026-05-03 v6 retro evidence suggests reasoning-architecture is the discriminator on cross-reference classification, but the failure mode here is output-structure conditional rules where reasoning-architecture appears to be neutral or actively harmful (the model honestly states absence rather than restructuring output). Worth testing whether non-reasoning tiers fall back to the simpler conditional-omit literally.
3. Post-processing strip in the recipe documentation: `sed -i '/^- No .* stated.*$/d; /^- None .*$/d; /^## What.s blocking$/d' <<< output` documented as a known-artefact filter. Pragmatic acknowledgement that prompt-only calibration on this task shape on `deepseek-r1:32b` cannot override the model's prior.
4. Accept HIT-with-edits status and let users strip by hand (current de-facto state).

The 2026-05-22 iteration ships the recipe in the sharpened state regardless of the dogfood MISS — the directives are still strictly better calibration than the prior substring blocklist (the positive-form catches paraphrases the blocklist would not, even if the model can still bypass it on this specific tier+model), and the COMMENT-N-CITATION directive is the first explicit guard against the body-headings-as-comments fabrication shape. Future contributors get directive-form rules to iterate on rather than substring blocklists to extend. Option 2 (tier reroute) is the next experiment worth running and is filed as the action item against this calibration entry.

### 2026-05-25 — Wrong/Correct anchor for numeric cap (issue #215)

Added a BULLET CAP constructive-rule directive with Wrong/Correct description under `## What happened`, plus constructive stop-after-3rd-bullet phrasing on `## What's blocking` and `## What's next`. The Wrong/Correct anchor follows the same lever that closed SUBJECT_LEN on `commit-message.md` (lines 34-40). The 2026-05-23T23:23:55Z MISS (12-line target produced 18 lines from splitting multi-clause events) motivates the "compress multi-clause events into single bullets" phrasing in the Correct description.

### 2026-05-22 PR #180 review pass — verbatim-crib mitigation + What's-next symmetry

Three refinements applied during PR #180 review in response to self-flagged risks plus gemini-code-assist feedback:

- **Verbatim-literal mitigation in the Wrong example.** The original Wrong/Correct anchor embedded the single literal sentence `- No explicit blockers stated in the thread.` inside the prompt template — which the 2026-05-22T11:11:53Z dogfood reproduced verbatim. Hypothesis: the model pattern-matched on the literal as a copyable crib rather than treating it as an example of a prohibited shape. The fix replaces the single-literal anchor with a *family-of-paraphrases* description that lists four real prior MISS phrasings (the 2026-05-21 paraphrase, the 2026-05-20 paraphrase, a shorter variant, and the with-comments variant) and explicitly frames them as *shape examples* rather than *the* forbidden string. The intent is to give the model the same shape signal without the verbatim copy attack surface. Empirical question for the next dogfood: does the family-of-paraphrases framing flip the directive from advisory to binding where the single-literal anchor did not? Either outcome is informative — a HIT confirms the verbatim-crib hypothesis; a MISS narrows the cause to the model's stronger "honest-acknowledgement-of-absence" prior, which the 2026-05-11 calibration entry hypothesised and the 2026-05-22 dogfood is consistent with.
- **`## What's next` Wrong/Correct anchor added** per the PR #173 dual-anchoring principle that few-shot examples must anchor both sides of any rule the prompt asserts. The original iteration added Wrong/Correct anchors for the blockers section only, asserting that the same rule applied to `## What's next` in prose without showing it. The fix adds a symmetric pair covering the zero-comments-no-next-action shape so the model sees the directive operationalised against both sections. Per gemini-code-assist's PR #180 review, the semantic test on the rule sentence is also generalised to cover both meanings ("the input does not contain a blocker" OR "the input does not contain a next action") so the directive itself enforces symmetry rather than relying on the model to generalise from the blockers-only phrasing.
- **Restored `no blockers` lowercase variant** to the belt-and-braces paraphrase enumeration alongside the existing `No blockers`. The lowercase form is a real prior MISS shape (the substring blocklist iteration on 2026-05-11 included it explicitly) and dropping it during the 2026-05-22 positive-form recast was an enumeration-coverage regression. The fix is mechanical; the enumeration is documented as a secondary belt-and-braces guard with the semantic test as the primary mechanism, so restoring this variant is additive coverage rather than a primary-mechanism change.

The Wrong/Correct example-family pattern is itself a calibration-pattern hypothesis worth testing on adjacent recipes — if the next dogfood HITs on the OMIT-EMPTY-SECTION shape, the family-of-paraphrases framing is a transferable pattern for any guard that previously relied on a single verbatim example. If the next dogfood MISSes on the same shape, the result strengthens the 2026-05-22 finding that prompt-only calibration cannot override `deepseek-r1:32b`'s honest-acknowledgement-of-absence prior, and option 2 (tier reroute) moves up the priority list.
