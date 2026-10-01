---
tier: prose
inputs:
  topic: string
  facts: string
  max_sentences: integer
---
# doc-section

## When to use

The user is drafting a technical document (usage guide, runbook, ADR, README section) and wants ONE short paragraph of prose for a single section, grounded in a list of facts the agent has gathered. The output is meant to be embeddable verbatim into the doc with at most trivial edits.

Distinct from adjacent recipes:

- `file-summary.md` is one sentence about a whole document.
- `summarise-issue.md` summarises existing content.
- This recipe *generates* prose for a section that does not yet exist, given a topic line and a fact list.

Typical inputs are 4–8 bulleted facts and a one-line topic; typical output is 2–4 sentences of flowing prose.

## Context to gather first

The agent collects two things before invoking the recipe:

1. A one-line description of what the section needs to cover.
2. A short bullet list of facts the model may use — environment variables, file names, behaviours, links to tracking tickets. Keep the list to what is actually relevant; padding the context invites the model to fabricate connections between unrelated bullets.

No git or repo introspection is needed — this recipe operates over agent-authored context, not source state.

## Prompt template

```
Write ONE short paragraph (≤{{max_sentences}} sentences) of guidance about: {{topic}}.

Plain UK English. No bullets, no headings, no bold, no inline code, no markdown. Output ONLY the paragraph itself, nothing else.

HARD RULES (non-negotiable; each addresses a real past MISS):

1. Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

2. If a sentence you are about to write begins with any of these phrases, DELETE that sentence before emitting the response. The phrases trigger regardless of what follows them:
   - "This approach …"
   - "This ensures …"
   - "Consequently, …"
   - "In summary, …"
   - "To address …"
   - "Overall, …"
   - "Ultimately, …"
   - "By doing so …"
   - "As a result, …"
   This list is non-negotiable; if the trigger phrase appears at the start of the final sentence, drop the whole sentence rather than rewording it.

3. If the final sentence paraphrases or restates an earlier sentence (even without a trigger phrase from rule 2), omit it from your response.

4. SENTENCE CAP — non-negotiable:
Count the sentences in your output. If the count exceeds {{max_sentences}}, DELETE sentences from the end until the count equals {{max_sentences}}. The cap is a hard ceiling, not a guideline. Stop after the {{max_sentences}}th sentence. Do not add a sentence that summarises or restates what the preceding sentences already said.
Wrong (max_sentences=4, output has 6 sentences): "The migration requires a database schema change before deploying the new service version. Run the migration script against the staging environment first to verify column additions succeed. The rollback procedure reverses only the schema additions without touching existing data. Teams should coordinate the deployment window with the on-call rotation. This ensures minimal disruption during the transition. The overall process is straightforward when the staging verification passes."
Correct (max_sentences=4, output has exactly 4 sentences): "The migration requires a database schema change before deploying the new service version. Run the migration script against the staging environment first to verify column additions succeed. The rollback procedure reverses only the schema additions without touching existing data. Teams should coordinate the deployment window with the on-call rotation."

Wrong (drafted with the closing recap pattern the rules above reject):
"Tune these settings only when the current defaults do not suit your specific needs, rather than applying changes preemptively. The four key knobs are enforced via CI environment variables which take precedence over your `.pr_agent.toml`, meaning local adjustments to those specific parameters will not take effect until AI-61 is resolved. Consequently, any configuration changes for these fields are strictly opt-in and should be avoided if the existing values are adequate."

Correct (same first two sentences; the trigger phrase "Consequently," fires rule 2 and the third sentence is dropped entirely):
"Tune these settings only when the current defaults do not suit your specific needs, rather than applying changes preemptively. The four key knobs are enforced via CI environment variables which take precedence over your `.pr_agent.toml`, meaning local adjustments to those specific parameters will not take effect until AI-61 is resolved."

=== Facts you may use (do not invent others; do not enumerate facts that are not load-bearing for the topic) ===
{{facts}}
```

## Variables

- `{{topic}}` — one-line description of what this paragraph needs to cover. Authored by the agent.
- `{{facts}}` — bulleted list of facts the model is allowed to reference. Authored by the agent or pasted from a source doc.
- `{{max_sentences}}` — sentence cap. Set 3 for tight guidance paragraphs; 4 for sections that need a "what / why / when" arc.

## Invocation

```bash
bash scripts/delegate.sh --recipe doc-section \
  --var topic="when and how to tune the four PR-agent knobs" \
  --var max_sentences=3 \
  --var facts='- PR_CODE_SUGGESTIONS__SUGGESTIONS_SCORE_THRESHOLD=8 is set in .pr-agent-base.variables in the central CI include
- Env vars take precedence over .pr_agent.toml in Dynaconf, so repos cannot lower these defaults via TOML
- Other knobs (model swap, extra_instructions, docs_style) are unaffected and freely configurable
- AI-61 tracks the threshold tuning saga and is the reason env vars override' \
  "Match a calm reference-doc voice. Stop after the substantive sentences."
```

The trailing prompt arg is the voice + reinforcement reminder; the recipe template carries the structural directives.

Single-quote `{{facts}}` rather than double-quoting it, as above. Facts for this recipe often name env vars and file paths, and inside double quotes the shell would expand a `$NAME` or eat a backslash before `delegate.sh` ever saw the value. The cost of single quotes is that the facts cannot contain an apostrophe — write "cannot" rather than "can't" — which is why the example above avoids one.

## Anti-hallucination guards (each line addresses a real past MISS)

- "ONE short paragraph (≤N sentences)" — without an explicit cap the prose tier reliably emits a fourth or fifth sentence that paraphrases the first.
- "Plain UK English. No bullets, no headings, no markdown" — the prose tier defaults to bullet lists for "concise guidance" prompts when the project's voice is flowing prose; SKILL.md's general guidance covers this and the recipe restates it locally.
- The three HARD RULES with the keyword-trigger DELETE list — the bare "Stop after the content sentences. Do not add a closing sentence that restates the point." directive from SKILL.md was applied verbatim in the 2026-05-20 doc-drafting session that filed issue #132 and *reduced but did not eliminate* the failure mode. The v5/v7 directive-rule pattern proven in the 2026-05-03 security-review delegation session, whose notes were archived out of `main` in 22395b2 (one-shot example alone did NOT shift the model's prior; explicit keyword-triggered rules with a "non-negotiable" framing did) is applied here.
- The Wrong/Correct one-shot uses the **exact** failing output and corrected output from issue #132's tuning-paragraph MISS (`ref_ts=2026-05-20T12:59:15Z`). The contrastive anchor is grounded in the failure shape rather than a paraphrase — same pattern that closed the `(#NN)` gap in `commit-message.md` and the declarative-rephrase gap in PR #86's T4 dogfood.
- The fact-list framing line `do not enumerate facts that are not load-bearing for the topic` was added to suppress the "list every fact in order" failure mode the prose tier exhibits when given a long bullet list; without it the model sometimes pads the paragraph by walking through every bullet rather than synthesising.

## Expected output shape

```
<2 to {{max_sentences}} sentences of flowing prose, plain UK English, no markup,
 no opening "This section…" filler, no closing recap sentence>
```

Verify before recording the verdict (`bash scripts/delegate-feedback.sh` followed by `hit`, `scaffold "<reason>"` or `miss "<reason>"`):

- Sentence count is ≤ `max_sentences`.
- The final sentence does not begin with any of the rule-2 trigger phrases.
- The final sentence introduces material content rather than restating an earlier sentence in different words.
- No bullets, no headings, no `**bold**`, no inline code fences around plain prose.

If the final sentence trips any of the above, hand-strip it and record the verdict as `miss` with a reason naming the specific trigger so the recipe's calibration notes can grow.

## Calibration notes

The dated calibration history for this recipe lives in [`docs/calibration/doc-section.md`](../docs/calibration/doc-section.md); add each new entry there.
