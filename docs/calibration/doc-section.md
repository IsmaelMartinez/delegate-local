# Calibration history for [`prompts/doc-section.md`](../../prompts/doc-section.md)

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
