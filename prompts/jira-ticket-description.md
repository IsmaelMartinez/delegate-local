---
inputs:
  source_text: string
  sentence_count: integer
---
# jira-ticket-description

## When to use

The agent is rewriting a short source paragraph (a roadmap stub, a planning note, a one-line backlog item, a Slack snippet) into a 2-3 sentence Jira ticket description suitable for pasting into the `Description` field of a Jira issue. Output is plain prose that preserves the source's filenames, paths, URLs, product names, and AWS service names verbatim, written in UK English, with no closing-recap padding and no merging of comma-coordinated technical objects into one.

Distinct from adjacent recipes:

- `doc-section.md` generates a section paragraph from a topic line plus a bulleted fact list. This recipe rewrites an existing source paragraph.
- `summarise-issue.md` summarises a long thread or log into a timeline. This recipe rewrites a short stub into ticket-shaped prose.
- `pr-description.md` drafts a GitHub PR body from a diff. This recipe targets the Jira-ticket idiom (2-3 sentences, no bullets, no headings).

Typical inputs are 1–3 sentences of planning prose with technical terms; typical output is 2-3 sentences of flowing UK English ticket-description prose.

## Context to gather first

The agent collects the source paragraph from the user (a roadmap entry, a backlog stub, a planning note) and decides on a sentence count (`2` or `3`). No git or repo introspection is needed — this recipe operates over user- or agent-supplied prose, not source state.

## Prompt template

```
Rewrite the source text below into a Jira ticket description of EXACTLY {{sentence_count}} sentences.

Plain UK English. Preserve all filenames, paths, URLs, and product names verbatim.

HARD RULES (non-negotiable; each addresses a real past MISS):

1. UK English. Use British spelling: -ise not -ize, -ourite not -orite, "utilise" not "utilize", "centralised" not "centralized", "behaviour" not "behavior", "optimise" not "optimize", "analyse" not "analyze", "organisation" not "organization", "favour" not "favor". If any US-spelled word appears in your draft, replace it with the British form before emitting.

2. Treat each comma-separated clause in the source as a distinct action or object. Do NOT merge two technical objects into one. A wildcard ACM certificate and a CloudFront distribution remain two separate things; merging them ("consolidate the wildcard ACM certificate into a single CloudFront distribution") is wrong because it loses one of the two objects. Preserve the count and identity of every technical object the source names.

3. Preserve filenames, file paths, URLs, AWS service names (CloudFront, ACM, Route 53, Lambda, EventBridge, etc.), and proper nouns EXACTLY as they appear in the source. Do not abbreviate, expand, re-format, or rename them.

4. Stop after the content sentences. Do not add a closing sentence that restates the point. Do not append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting") that summarises a downstream effect or implication. End on a finite verb introducing new content, or stop.

5. The final sentence of your output must NOT begin with any of these openers (case-insensitive): "this", "to ensure", "to align", "allowing", "enabling", "supporting", or any participle (-ing form) that restates the prior point. If the final sentence would begin with one of these, rephrase it to introduce material content while maintaining the required sentence count — do not drop the sentence (the EXACTLY {{sentence_count}} constraint takes precedence).

6. Output ONLY the rewritten description text. No bullets, no headings, no bold, no inline code, no markdown, no preamble ("Here is the description:"), no closing acknowledgement.

Wrong (drafted with the comma-coordinated-merge failure mode this recipe rejects; source mentioned TWO distinct objects, the output merged them into ONE):
Source: "Migrate the legacy users table to a partitioned schema, and add a backfill job that replays the existing 14M rows."
Output: "Migrate the legacy users table by consolidating the partitioned schema into the existing backfill job that replays 14M rows, utilizing the new schema design to align with the partition strategy."

Correct (same source; preserves the two distinct actions, demonstrates UK spelling with "utilising" rather than the Wrong's "utilizing", stops on a finite-verb sentence rather than a "to align" tail):
Source: "Migrate the legacy users table to a partitioned schema, and add a backfill job that replays the existing 14M rows."
Output: "Migrate the legacy users table to a partitioned schema. Add a backfill job utilising the new partitions to replay the existing 14M rows."

=== Source text ===
{{source_text}}
```

## Variables

- `{{source_text}}` — the source paragraph to rewrite. The roadmap stub, backlog item, planning note, or Slack snippet that needs to become a Jira ticket description. Authored by the user or pasted by the agent.
- `{{sentence_count}}` — `2` or `3`. The sentence cap is explicit because without it the prose tier reliably emits a fourth or fifth sentence that paraphrases the first.

## Invocation

```bash
bash scripts/delegate.sh --recipe jira-ticket-description \
  --var sentence_count=3 \
  --var source_text="Phase 3: route api.example.com and admin.example.com via a wildcard ACM certificate, and consolidate per-service CloudFront distributions into one distribution with path-based routing." \
  prose "2-3 sentence Jira ticket description. UK English. Preserve every technical object distinctly."
```

The trailing prompt arg is the voice + reinforcement reminder; the recipe template carries the structural directives.

## Anti-hallucination guards (each line addresses a real past MISS)

- HARD RULE 1 (UK English glossary with explicit US/UK pairs) — the 2026-05-21 calibration MISS used "utilizing" inside an otherwise British-voice paragraph. The bare instruction "use British spelling" is insufficient because the model's prior on technical prose is US English; listing the exact word that drifted (`-ize`/`-ise` pairs, `utilise`/`utilize`, `centralise`/`centralized`, etc.) gives the model both forms to compare against, which is the v5-style sharpening pattern proven in `experiments/sessions/2026-05-03-security-review-delegation/`.
- HARD RULE 2 (treat comma-separated clauses as distinct objects) — the 2026-05-21 MISS merged "wildcard ACM certificate" and "consolidate per-service distributions into one CloudFront distribution" (two distinct actions on two distinct AWS resources) into "consolidate the wildcard ACM certificate into a single CloudFront distribution" (one nonsensical action). The verbatim Wrong/Correct example below the rules pairs that failure shape with its corrected output so the model has a contrastive anchor.
- HARD RULE 3 (preserve filenames, paths, URLs, AWS service names verbatim) — standard prose-tier preservation rule; the prose tier defaults to abbreviating or paraphrasing technical proper nouns ("the ACM cert" instead of "wildcard ACM certificate") when asked to "tighten" or "rewrite for ticket prose". Listing the AWS service names explicitly (CloudFront, ACM, Route 53, Lambda, EventBridge) gives the model concrete anchors.
- HARD RULE 4 (anti-padding directive — canonical text adopted in PR #144, which closes issue #138) — verbatim from SKILL.md's Discipline section as sharpened by PR #144. The 2026-05-21 MISS appended "to align with the new routing configuration" — exactly the closing-restatement tail this directive blocks.
- HARD RULE 5 (closing-sentence opener blocklist) — explicit list of openers that empirically begin closing-recap sentences (`this`, `to ensure`, `to align`, `allowing`, `enabling`, `supporting`, plus the participle family). The 2026-05-21 MISS's tail began with "to align" — that exact opener is in the blocklist. Hypothesised based on the single-session signal; mark as "to be verified across 3+ future sessions" (see Calibration notes).
- HARD RULE 6 (output only — no markdown, no preamble) — without it the prose tier wraps the output in a ` ```text` fence, prefixes with "Here is the Jira description:", or appends a "Let me know if you'd like adjustments." closer. Same family as `polish-reply.md` and `file-summary.md`'s output-only rules.
- The Wrong/Correct one-shot uses a DIFFERENT DOMAIN (database migration) from the actual 2026-05-21 MISS (AWS routing) so it does not leak the answer for the canonical source the recipe is calibrated against. The contrastive anchor is the failure SHAPE (comma-coordinated merge + US spelling drift + "to align" tail), grounded in a parallel scenario rather than a paraphrase.

## Expected output shape

```
<2 or 3 sentences of flowing UK-English prose, plain text, no markup,
 no opening "This ticket…" filler, no closing "to align with…" recap,
 every technical object from the source preserved as a distinct noun phrase>
```

Verify before recording verdict via `bash scripts/delegate-feedback.sh hit|miss [reason]`:

- Sentence count is exactly `{{sentence_count}}`.
- No US spelling drift: search the output for `-ize`, `-ized`, `-izing`, `-ization`, `behavior`, `favor`, `favorite`, `analyze`, `optimize`, `utilize`. Any hit is a MISS.
- Every technical object the source named appears in the output as a distinct noun phrase. Count comma-separated clauses in the source; count noun phrases in the output; they should match.
- Filenames, paths, URLs, and AWS service names appear verbatim. No abbreviations.
- The final sentence does not begin with any rule-5 trigger phrase (`this`, `to ensure`, `to align`, `allowing`, `enabling`, `supporting`, `-ing` participle).
- No markdown, no preamble, no closer.

If any check fails, hand-strip the offending sentence and record the verdict as `miss` with a reason naming the specific failure (e.g. `miss "merged ACM cert + CloudFront into one object"`, `miss "utilizing instead of utilising"`, `miss "to align tail despite blocklist"`) so the recipe's calibration notes can grow.

## Calibration notes

This recipe is distilled from the 2026-05-21 Jira-description rewriting session that filed issue #141. Five atomic prose-tier delegations against `qwen3.6:35b-a3b-q8_0` produced 4 HIT and 1 MISS; the MISS exhibited three failure modes in one response, each of which has a dedicated guard in the recipe above.

### 2026-05-21 — session that surfaced the pattern (issue #141)

The session rewrote short roadmap stubs into Jira ticket descriptions for a portfolio of AWS infrastructure tickets. The prompt for each call asked for "2-3 sentence ticket description, UK English, preserve technical names" with no further structural directives. Four of the five outputs were HITs and kept verbatim. The fifth (the Phase 3 subdomain-routing stub) MISSed with the three-failure-mode shape this recipe is designed to suppress.

The MISS source paragraph was:

> "Phase 3: route api.example.com and admin.example.com via a wildcard ACM certificate, and consolidate per-service CloudFront distributions into one distribution with path-based routing."

A reconstructed approximation of the MISS output, assembled from the verbatim fragments captured in issue #141 (the original full paragraph was not preserved; treat this as directionally correct, not character-exact — included so a future recipe edit has a single block to dogfood against rather than three loose fragments):

> "Phase 3 will route api.example.com and admin.example.com by consolidating the wildcard ACM certificate into a single CloudFront distribution with path-based routing, utilizing the new wildcard certificate to align with the new routing configuration."

The three verbatim fragments that ARE preserved from the original MISS appear in the provenance table below (`consolidate the wildcard ACM certificate into a single CloudFront distribution`, `utilizing the new wildcard certificate`, `to align with the new routing configuration`) — those are the load-bearing evidence; the block above is a reconstruction for narrative continuity.

Three failure modes appeared in one response. The output collapsed the two comma-coordinated technical objects (the wildcard ACM certificate AND the consolidated CloudFront distribution) into one nonsensical action: "consolidate the wildcard ACM certificate into a single CloudFront distribution". The same output used "utilizing" in an otherwise British-voice paragraph. The same output closed with "to align with the new routing configuration" — pure restatement padding with the participle-clause shape SKILL.md's anti-padding directive blocks.

### Provenance of each guard

| Guard | Source | Failure mode addressed | Evidence (verbatim wrong output) |
|-------|--------|------------------------|----------------------------------|
| HARD RULE 1 (UK-spelling glossary) | New for this recipe. The 2026-05-21 MISS used "utilizing". The bare "UK English" instruction did not catch it. | British→US spelling drift on common -ize/-ise verbs | "...utilizing the new wildcard certificate..." |
| HARD RULE 2 (no-merge directive) | New for this recipe. Hypothesised from the 2026-05-21 MISS; the failure mode (comma-coordinated technical objects merged into one) has not been retested across future sessions yet. Mark as to-be-verified. | Factual collapse of two technical objects into one | "consolidate the wildcard ACM certificate into a single CloudFront distribution" (source had a certificate AND a distribution as two distinct objects) |
| HARD RULE 3 (verbatim-preserve filenames/paths/URLs/AWS service names) | Standard prose-tier preservation rule; restated locally for resilience. The 2026-05-21 MISS preserved `api.example.com` and `admin.example.com` correctly but mangled "wildcard ACM certificate" by re-purposing it as the object of "consolidate". | Abbreviation or re-purposing of technical proper nouns | Same merge as rule 2 |
| HARD RULE 4 (anti-padding directive, sharpened) | Verbatim from SKILL.md's Discipline section as sharpened in PR #144 (closes issue #138). Established practice. | Closing-recap sentence / participial-clause padding | "...to align with the new routing configuration." |
| HARD RULE 5 (closing-sentence opener blocklist) | New for this recipe. Hypothesised based on the 2026-05-21 MISS's "to align" tail; the opener blocklist (`this`, `to ensure`, `to align`, `allowing`, `enabling`, `supporting`) is drawn from this project's metrics history and `doc-section.md`'s rule-2 trigger list. Mark as to-be-verified across future sessions. | Closing sentence beginning with a restatement opener | "to align with the new routing configuration" |
| HARD RULE 6 (output-only) | Same as `polish-reply.md` and `file-summary.md`'s output-only rules. The prose tier defaults to wrapping ticket-description output in a ` ```text` fence or prefacing with "Here is the description:". | Preamble, markdown fencing, closing acknowledgement | (general prose-tier pattern; not specific to the 2026-05-21 MISS) |
| Wrong/Correct one-shot (database migration) | New for this recipe. Uses a database-migration domain rather than AWS routing so it does not leak the answer for the canonical AWS source. | All three failure modes combined (merge + US spelling + "to align" tail) | Source: "Migrate the legacy users table to a partitioned schema, and add a backfill job that replays the existing 14M rows." Wrong: merges the schema and the backfill job, uses "utilizing", appends "to align with the partition strategy". |

### What's not yet measured

The British-spelling guard (rule 1) is a mitigation, not a guaranteed cure. The 2026-05-21 calibration had only one drift event (a single "utilizing"); with more sessions this guard becomes empirically grounded. Pre-loading the glossary is the recipe's best lever for catching drift before it hits the output. If the glossary slips on a specific word, the user's escape hatch is post-processing with `sed -E 's/utilizing/utilising/g; s/centralized/centralised/g; ...'` or running the output through `aspell --lang=en_GB`. A future iteration could ship a post-processing helper but the per-call cost of one MISS does not yet justify the engineering investment.

The no-merge guard (rule 2) and the closing-opener blocklist (rule 5) are hypothesised from the single 2026-05-21 MISS and have not been retested across multiple future sessions yet. Mark them as "to be verified across 3+ future sessions" — once enough HIT/MISS data accumulates against this recipe to confirm the guards actually close the failure modes, the recipe graduates from "structural starting point" to "validated", same path the other recipes in this directory took.

Like `doc-section.md`, this recipe ships without a dedicated T-series fixture. The natural fixture is a structural scorer that asserts UK spelling (regex over the `-ize`/`-ization`/`utilize`/`behavior`/`favor`/`analyze` set), counts noun phrases against the source's comma-separated clause count, and applies the rule-5 opener blocklist as a final-sentence regex. Defer until there is enough HIT-class output to calibrate against.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is rewriting a short source paragraph into ticket-shaped prose; it is not classification, not extraction, not multi-step reasoning. Anyone reaching for `reasoning` here is over-spending — the 2026-05-21 calibration confirmed prose-tier produces HIT-class output on 4 of 5 calls with this recipe's guards in place.
