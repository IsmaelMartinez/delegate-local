---
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
- `summarise-diff.md` / `summarise-issue.md` summarise existing content.
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
  --var facts="$(cat <<'FACTS'
- PR_CODE_SUGGESTIONS__SUGGESTIONS_SCORE_THRESHOLD=8 is set in .pr-agent-base.variables in the central CI include
- Env vars take precedence over .pr_agent.toml in Dynaconf, so repos can't lower these defaults via TOML
- Other knobs (model swap, extra_instructions, docs_style) are unaffected and freely configurable
- AI-61 tracks the threshold tuning saga and is the reason env vars override
FACTS
)" \
  prose "Match a calm reference-doc voice. Stop after the substantive sentences."
```

The trailing prompt arg is the voice + reinforcement reminder; the recipe template carries the structural directives.

## Anti-hallucination guards (each line addresses a real past MISS)

- "ONE short paragraph (≤N sentences)" — without an explicit cap the prose tier reliably emits a fourth or fifth sentence that paraphrases the first.
- "Plain UK English. No bullets, no headings, no markdown" — the prose tier defaults to bullet lists for "concise guidance" prompts when the project's voice is flowing prose; SKILL.md's general guidance covers this and the recipe restates it locally.
- The three HARD RULES with the keyword-trigger DELETE list — the bare "Stop after the content sentences. Do not add a closing sentence that restates the point." directive from SKILL.md was applied verbatim in the 2026-05-20 doc-drafting session that filed issue #132 and *reduced but did not eliminate* the failure mode. The v5/v7 directive-rule pattern proven in `experiments/sessions/2026-05-03-security-review-delegation/` (one-shot example alone did NOT shift the model's prior; explicit keyword-triggered rules with a "non-negotiable" framing did) is applied here.
- The Wrong/Correct one-shot uses the **exact** failing output and corrected output from issue #132's tuning-paragraph MISS (`ref_ts=2026-05-20T12:59:15Z`). The contrastive anchor is grounded in the failure shape rather than a paraphrase — same pattern that closed the `(#NN)` gap in `commit-message.md` and the declarative-rephrase gap in PR #86's T4 dogfood.
- The fact-list framing line `do not enumerate facts that are not load-bearing for the topic` was added to suppress the "list every fact in order" failure mode the prose tier exhibits when given a long bullet list; without it the model sometimes pads the paragraph by walking through every bullet rather than synthesising.

## Expected output shape

```
<2 to {{max_sentences}} sentences of flowing prose, plain UK English, no markup,
 no opening "This section…" filler, no closing recap sentence>
```

Verify before recording verdict via `bash scripts/delegate-feedback.sh hit|miss [reason]`:

- Sentence count is ≤ `max_sentences`.
- The final sentence does not begin with any of the rule-2 trigger phrases.
- The final sentence introduces material content rather than restating an earlier sentence in different words.
- No bullets, no headings, no `**bold**`, no inline code fences around plain prose.

If the final sentence trips any of the above, hand-strip it and record the verdict as `miss` with a reason naming the specific trigger so the recipe's calibration notes can grow.

## Calibration notes

This recipe is distilled from the 2026-05-20 doc-drafting session documented in issue #132. Eight delegations against `qwen3.6:35b-a3b-q8_0` (prose tier) produced 5 HIT and 3 MISS; all three MISSes were the closing-recap pattern this recipe is designed to suppress.

### 2026-05-20 — session that surfaced the pattern (issue #132)

The session drafted paragraphs for sections of a Claude Code / pr-agent usage guide. The prompt for each section included the verbatim anti-padding directive from SKILL.md (`Stop after the content sentences. Do not add a closing sentence that restates the point.`) and the model produced the rejected shape on 3 of 8 paragraphs anyway.

- `ref_ts=2026-05-20T12:58:16Z` — default-behaviour paragraph. Output's third sentence: "This approach ensures concise, actionable feedback without unnecessary progress notifications or redundant commentary." Pure restatement padding, no new information. Recorded miss; sentence stripped by hand.
- `ref_ts=2026-05-20T12:59:15Z` — tuning paragraph. Output's third sentence: "Consequently, any configuration changes for these fields are strictly opt-in and should be avoided if the existing values are adequate." Restates the previous sentence using a connective (`Consequently,`) and introduces a logical contradiction (the prior sentence said the env vars override TOML, so the four knobs are *not* opt-in). Recorded miss; sentence stripped by hand. **This is the exact pair used as the Wrong/Correct one-shot above.**
- `ref_ts=2026-05-20T12:57:05Z` — audience paragraph. Different failure family (factual confusion, not padding). Single-instance, not generalisable enough for a recipe directive.

The same shape recurred in a later 2026-05-20 session (`ref_ts=2026-05-20T22:37:28Z`): "leaked 'cascading aborts' jargon despite no-implementation-detail rule; appended trailing 'ensuring X' padding clause despite explicit Stop directive." Two MISS sessions a few hours apart against the same model with the same SKILL.md-level directive confirms the bare-directive approach is insufficient and a recipe-level v5-style intervention is warranted.

### Provenance of each guard

| Guard | Source |
|-------|--------|
| `ONE short paragraph (≤N sentences)` | The 2026-05-20 HITs all used an explicit sentence cap; the MISSes mostly held the cap but emitted a recap sentence within the cap. |
| `Plain UK English. No bullets, no headings, no bold, no inline code, no markdown` | General prose-tier default in SKILL.md; restated locally for resilience. Inline elements (`**bold**`, `` `code` ``) are listed explicitly because the prose tier sometimes interprets bare "no markdown" as a structural-only constraint and emits inline emphasis for what it considers "important" words. The PR #135 review surfaced this on first round. |
| HARD RULE 1 (Stop after substantive sentences) | Verbatim from SKILL.md Discipline section; established practice. |
| HARD RULE 2 (keyword-triggered DELETE list) | New for this recipe. The phrase list is drawn from the actual MISS outputs in issue #132 and the broader metrics history's PADDING_RECAP rows (10 of 18 recent MISSes classified as recap-shaped on 2026-05-21 — see `metrics.jsonl` rows tagged `kept=false`). |
| HARD RULE 3 (final-sentence paraphrase removal) | New for this recipe. Issue #132 noted that some MISSes used legitimate-looking opening clauses that still amounted to restatement (e.g. "should be avoided if the existing values are adequate" without a trigger phrase from rule 2). Rule 3 catches that residual shape. Phrased in natural language rather than "OUTPUT only the first N-1 sentences" because the prose-tier model in the 35B range parses mathematical variable notation unreliably (PR #135 review surfaced this — natural-language rewording is the load-bearing change). |
| Wrong/Correct one-shot | Verbatim from issue #132's tuning-paragraph MISS (`ref_ts=2026-05-20T12:59:15Z`); the Correct version is the hand-edited form the user kept. |

### 2026-05-25 — Wrong/Correct anchor for numeric cap (issue #215)

Added HARD RULE 4 (SENTENCE CAP) with a Wrong/Correct one-shot anchor. The Wrong example shows 6 sentences when the cap is 4; the Correct example shows exactly 4. Same lever that closed SUBJECT_LEN on `commit-message.md` (lines 34-40). The constructive-rule phrasing ("Stop after the Nth sentence. Do not add a sentence that summarises or restates what the preceding sentences already said.") follows the issue #215 hypothesis that positive construction binds more reliably than bare numeric descriptors on greedy decoding.

### Standing regression bench (added 2026-06-23)

The deterministic scorer this section used to defer now exists as `tests/bench-doc-section-padding.sh`. It drives `--recipe doc-section` over diverse fixtures and flags the closing-recap / participial padding tail using the production `padding_re` extracted from `delegate.sh` at runtime (so it cannot drift from `no_padding_tail`), plus a sentence-cap check for HARD RULE 4. It is the recipe's only regression coverage — doc-section ships no `checks:` block, so production enforces neither padding nor cap. The live gate is opt-in (`BENCH_GATE=1 bash tests/bench-doc-section-padding.sh`); an offline, model-free wiring smoke is wired into `tests/run-tests.sh`. This follows the per-recipe-bench pattern established for `commit-message` in ADR 0026 (the archived `experiments/score-tN.sh` harness it once pointed at is gone after the lean-core reset).

Baseline (2026-06-23, both Qwen3.6-35B backends): MLX-8bit clean on all six fixtures; Ollama-q8_0 emits a participial padding tail (", preventing repositories from lowering this default directly") on the `pr-agent-tuning` fixture — the same issue #132 input — which HARD RULE 1 forbids and the bench now catches. The directive holds on MLX-8bit but not on q8_0 for this input. Tightening it without over-suppressing legitimate participials is a separate calibration decision: the structural `-ing` rule already covers "preventing", so per-verb enumeration is not the lever (see the 2026-06-07 treadmill note in `commit-message.md`). Left as a flagged follow-up rather than a rushed prompt change.
