# Prompts library

This directory holds calibrated prompt recipes for tasks that recurringly fit the `delegate-local` skill's trigger surface — drafting, summarising, classifying, extracting, rewriting. Each file encodes a task shape that has been empirically validated against a local prose-tier or code-tier model (defaults from `scripts/pick-model.sh`) and produced HIT-class output (verbatim or near-verbatim usable, per `scripts/delegate-feedback.sh`).

## Why this directory exists

Small / local models (≤80B) need much more handholding than Opus-class. Abstract style descriptors like "match the project's terse style" or "concise commit message" reliably yield bullet lists when the project's recent style is flowing prose — the model defaults to whatever shape is most common in its training, not what the calling agent imagined. The fix that consistently turns MISS into HIT in real sessions is verbatim-example anchoring plus explicit anti-hallucination guards.

Rather than rediscover that fix every conversation, the proven prompts live here as versioned recipes. Each recipe ships with the skill so every install (Claude Code plugin, `npx skills add`) inherits the calibration. Recipes evolve append-style: every recurring HIT graduates to a recipe entry; every MISS that names a missing recipe gets one filed.

## How a recipe is structured

Each `<task>.md` file uses these sections:

```
# <task name>

## When to use
A one-paragraph description of the task shape. If the user's request matches
this shape, this recipe is the right starting point.

## Context to gather first
A short list of the inputs the agent must collect before invoking the recipe
(e.g. `git log --pretty=fuller -3`, `git diff main --stat`, recent merged
PR bodies). The recipe will not produce HIT-class output without these.

## Prompt template
The exact text to feed to `bash scripts/delegate.sh ...` inside a fenced code
block. Uses `{{name}}` placeholders that map to per-call context (gathered
commands, agent-authored prose). Includes explicit anti-hallucination guards
distilled from past MISS patterns (no PR-number prefix, no indentation, no
invented example output, etc.).

## Variables
One bullet per `{{name}}` placeholder, naming the source command or the
shape of agent-authored content the value should hold.

## Invocation
A copy-pasteable `bash scripts/delegate.sh --recipe <name> --var k=v ... <tier>
"<prompt>"` example showing how to wire the placeholders to real commands.

## Expected output shape
What HIT looks like. Lets the agent verify the output before recording
the verdict via `bash scripts/delegate-feedback.sh hit|miss [reason]`.

## Calibration notes
Provenance: which session's HIT validated this recipe, and what specific
guard each line addresses (links to the metrics ts when possible). New
guards added when a follow-up MISS surfaces a new failure mode.
```

## How `--recipe` and `--var` work

`scripts/delegate.sh --recipe NAME [--var key=value ...] <tier> "<prompt>"` loads `prompts/<NAME>.md`, extracts the first fenced code block under `## Prompt template`, substitutes each `{{key}}` placeholder with the matching `--var` value, then sends the result to the model exactly like a hand-assembled prompt. The `{{stdin}}` placeholder is auto-substituted with piped stdin when present, so a recipe can fold a single large input (a diff, a log) into a fixed slot without forcing the agent to escape it through `--var`. Unsubstituted placeholders are a hard error rather than silently passing through — the recipe authors put the guard there because a partly-substituted template usually means a missed input rather than a deliberate omission, and producing a low-quality answer is worse than failing fast. The trailing prompt arg becomes optional when `--recipe` is set; in practice it is the one-line "match the example shape and tone" reinforcement that the recipe's invocation example demonstrates.

## How to add a new recipe

When you spot a recurring task pattern that doesn't have a recipe yet:

1. Use the skill on the task with hand-crafted anchoring (verbatim recent examples, explicit guards), then call `bash scripts/delegate-feedback.sh hit "<reason>"` if the output was usable verbatim or with trivial edits.
2. Distil the working prompt into the four sections above. Keep it short — the recipe is the minimum context that consistently produces HIT, not a manifesto.
3. Add an entry to the SKILL.md "Recipes" pointer so the agent knows the recipe exists.
4. Where it makes sense, mirror the task shape into `evals/eval-set.json` as a positive paraphrase so the trigger eval ensures the description still fires on the pattern.

### Optional conventions for new recipes (Phase 12 Track B, #161)

Two conventions are recommended for new recipes — both optional. Existing recipes keep their current shape and migrate only when touched for other reasons. No bulk reformat. The conventions and their rationales:

#### Convention 1 — One-sentence identity-and-scope opener at the top of `## Prompt template`

Open the template body with a single sentence that names the task and explicitly forbids the most common drift. NOT a persona. The persona idiom ("You are an expert X", "Act as a senior Y") is rejected in this library on empirical grounds — see "What this library does NOT adopt" below for the Zheng et al. and Wharton replication evidence. The identity-and-scope opener does a different job: it consolidates directives that today are scattered across `## Anti-hallucination guards` into one short up-front sentence the model encounters before the structural directives. Task plus forbidden actions, e.g.:

> "Draft a single commit message subject line from the staged diff below. Do not invent file paths."

Empirically the recipes that already calibrate well (commit-message.md, polish-reply.md) repeat the same forbidden-action callouts across multiple guards; surfacing them once at the top of the template prevents the guard list from inflating linearly with every new failure mode. Anchor every forbidden action in a real past MISS, the same way the existing guards do, so the opener doesn't drift into speculative restriction.

#### Convention 2 — Optional `inputs:` block in YAML frontmatter for pre-flight type validation

A recipe MAY declare its expected `--var` types via a flat YAML frontmatter block at the top of the file. `delegate.sh --recipe NAME` validates each provided `--var key=value` against the declared type before contacting the model, exiting 2 with a clear error if a required input is missing or a value fails its type check. Example frontmatter:

```yaml
---
inputs:
  pr_number: integer
  body: string
  anchor: string?
---
```

Supported types: `integer`, `string`, `integer?`, `string?`. The `?` suffix marks the input as optional (absent `--var` is allowed; if provided, the value is still type-checked). An optional input may have a `{{key}}` placeholder in the template body: when the caller omits the `--var`, `delegate.sh` collapses that placeholder to the empty string before the unsubstituted-placeholder guard runs, so a recipe can expose an override most callers leave off (see `prompts/commit-message.md`'s `type`) without the placeholder becoming all-or-nothing. The block is constrained to flat `key: type` pairs only — no nesting, no anchors, no flow style — so `awk` parses it without pulling in `yq` and the "two bash scripts" rule holds. Heavier YAML features (block scalars, arrays, anchors) stay rejected by design rather than imported by accident, mirroring the Microsoft Prompty rejection rationale in "What this library does NOT adopt" below.

The validator passes undeclared `--var` keys through untouched — strict-mode rejection of unknown keys is deferred until lazy migration is more complete, so a recipe that declares only `pr_number` doesn't break callers passing `--var notes=...`. Recipes without an `inputs:` block skip the validation entirely (the back-compat path), so the convention is genuinely opt-in.

The `{{stdin}}` placeholder maps to a declared `stdin: string` input — a recipe can require piped context via the typed surface without forcing the caller to pass it twice. Validation runs before placeholder substitution so the caller sees the type error rather than an opaque "missing placeholder" downstream message. See `prompts/commit-message.md` for a worked example combining both conventions.

#### Convention 3 — When directive enumeration saturates, escalate via contrastive anchors, not more enumeration (Phase 15)

Recurring observation across `prompts/commit-message.md`'s 2026-05-10/11/12/21/22/23/24 calibration cycle, on `qwen3.6:35b-a3b-q8_0` under greedy decoding: adding more forbidden-phrase examples to a directive enumeration has a measurable ceiling. The first few enumerated items bind well (the model avoids them) but each subsequent addition produces diminishing returns until the next MISS surfaces a structurally-equivalent phrase the enumeration did not name. The 2026-05-24 Phase 15 Track A baseline measured this concretely: T4 against the current `commit-message.md` template scored 12/18 (mean 0.67) on prose tier with both SUBJECT_LEN and BODY_NO_PADDING failing every rep, despite the template body literally enumerating the failing verbs. This is the directive-binding ceiling.

The lever that pushed past the ceiling (Phase 15 Track A, measured 18/18 mean 1.00 on the same fixture) was promoting a single Wrong/Correct contrastive anchor to four pairs covering the three primary shape families — participial-form, declarative-form, and closing-flourish form — anchored on real past MISS evidence. The contrastive pair gives the model a concrete imitation target ("this is the wrong shape, this is the same idea in the right shape") that the enumeration alone does not. The empirical evidence runs back to 2026-05-10 (the `(#NN)` gap closed by promoting a bare negation to a Wrong/Correct contrastive) and 2026-05-12 (closes-the-gap closed the same way) — Phase 15 Track A generalises the pattern as a convention.

Two recipe-authoring rules drawn from this evidence:

1. **Domain-neutral Correct examples.** The first iteration of Phase 15 Track A used Correct examples that were plausibly about the actual diff being committed (recipe-adjacent phrasing about fixtures and anti-padding). The model copied a Correct sentence verbatim into the body because it was on-topic. Switching to domain-neutral content (endpoint validation, migration scripts, rate limiters, contract-vs-payload) bound the pattern without leaking content. Anchor Wrong/Correct examples in subject matter the recipe's real callers do NOT routinely touch.

2. **Verb-substitution is the next-level ceiling.** Phase 15 Track A measurement also surfaced that the model now AVOIDS the enumerated verbs (`providing`, `allowing`, `ensuring`) but defaults to structurally-equivalent unenumerated verbs (`replacing`, `supporting`, `reflecting`). Verb-level enumeration succeeds on coverage but the underlying structural pattern persists. When a follow-up MISS surfaces a structurally-equivalent unenumerated phrase, the choice is: extend the enumeration AND the scorer in lockstep (the current Phase 13 convention), or move to a structural pattern matcher (e.g. `, [a-z]+ing` trailing-clause regex) with calibrated false-positive thresholds. The latter is the next-level lever; the former is the cheap first move.

Tier escalation as a lever was tested empirically in Phase 15 Track B (same session) and returned a negative result for the commit-message recipe: the code tier (`qwen3-coder-next:latest`, same post-edit fixture, 3 reps) scored 15/18 mean 0.83 against the prose tier's 18/18, all three code-tier reps appending `(#NN)` to the subject despite the explicit Wrong/Correct anchor. Speculative reading: code-specialised models treat recent-commits anchors as a sequence to extend, including trailing `(#NN)` patterns from squash-merges. Tier escalation may help on different recipe shapes (the Phase 10 v6 retrospective found reasoning-architecture beats parameter count for closed-form classification with cross-reference rules) but is not a uniform improvement and needs per-recipe empirical validation rather than assumption.

The order-of-operations for a recipe whose directive enumeration is saturating: contrastive Wrong/Correct anchor with domain-neutral content first; call-site reinforcement appended to the trailing prompt second (the 2026-05-23 prefix-hint promotion on `commit-message.md` is the worked example); structural scorer extension third; tier escalation only after empirical per-recipe measurement, not by default.

#### Convention 4 — `flaky_on_models:` frontmatter tier-gate (Phase 16 Track A)

When a recipe has documented empirical evidence of unreliable behaviour on a specific model class (typically: parameter-count-driven stalls, structural-output budget overruns, or known-hallucination shapes), declare a `flaky_on_models:` list in the recipe's YAML frontmatter. Entries are case-insensitive substrings matched against the resolved model name. When the wrapper resolves a tier to a model matching any listed substring, `scripts/delegate.sh` exits 4 with a stderr message naming the recipe, the resolved model, the matched pattern, and three recovery options (hand-write, route to a different tier, override via `DELEGATE_FORCE_FLAKY=1`). The metrics JSONL row is tagged `exit_status:4` so `audit-metrics.sh` can pivot on flaky-gate refusals later. Example frontmatter:

```yaml
---
inputs:
  recent_prs: string
  diff_stat: string
  context: string
flaky_on_models:
  - qwen3.6:35b
  - qwen3-next:80b
---
```

The gate runs BEFORE the pre-flight canary because the refusal is structural ("this recipe will not work reliably on this model class") rather than dynamic ("the model isn't responding right now") — no point probing a model the recipe already classifies as unreliable. Back-compat: recipes without a `flaky_on_models:` block skip the check entirely; the convention is genuinely opt-in.

Two recipe-authoring rules for the field:

1. **Anchor every listed substring in measured evidence.** A flaky_on_models entry is a structural claim that this recipe will not work reliably on this model class; the recipe's calibration notes must cite the empirical observation that justified the entry. `prompts/pr-description.md` is the worked example — the 35B-class entries are grounded in 2026-05-10/11/12/13 stall measurements across Ollama and MLX, on inputs ranging from 612 bytes to 5.2 KB.

2. **List substrings, not exact model names.** Model names vary by quantisation suffix, backend (Ollama `:`, HuggingFace `/`), and underscore/hyphen conventions; a substring like `qwen3.6:35b` matches `qwen3.6:35b-a3b-q8_0`, `qwen3.6:35b-instruct`, and (case-insensitively) `Qwen3.6:35B`. List all naming conventions you've observed in your own host's `pick-model.sh` resolution so the gate adapts across upgrades. Don't list full quantisation suffixes — they change too often.

The opt-out env var `DELEGATE_FORCE_FLAKY=1` exists specifically so callers can capture fresh evidence that the flaky-class behaviour has changed across model upgrades. If a future Qwen3.7 release behaves better on the pr-description shape, override the gate once, measure, and update the frontmatter — don't silently rip the gate out.

#### Convention 5 — Scaffold-then-polish for prose-tier delegations against digests (Phase 17 Track C)

When a recipe ingests a structured digest (action items, fact list, metrics rollup, multi-source summary) and needs to emit flowing prose, the prompt verb matters more than the prompt detail. Prefer asking the model to `polish` a scaffold over asking it to `write` a paragraph from a digest, on 35B-class prose-tier models. The discriminator is the verb: `write` invites invention; `polish` preserves substance.

The scaffold the agent hand-writes should encode the facts as positions inside sentences, e.g. `[T4 baseline was X] then [the intervention was Y] then [the measurement was Z]`. Not a bullet list of facts the model is free to reorder or omit. Scaffold positions are guard rails — the model fills them as prose without authority to drop or reorder them.

On 2026-05-24, during construction of an audio-podcast script from a digest of factual data, prose-tier `qwen3.6:35b-a3b-q8_0` hallucinated supporting detail when asked to `write` the script: fabricated ablation statistics, fabricated experiment counts, invented quotation attributions. Two consecutive MISSes were recorded on the same prose-tier model for this task shape. The successful third attempt switched the prompt framing — the agent hand-wrote a scaffold (paragraph skeleton with topic-sentence positions and fact positions), then asked the same model to `polish` it (smooth the prose, vary sentence shape, preserve all named facts verbatim, invent nothing). Result: HIT verbatim, zero hallucination.

Recipes that produce closed-form structured output (commit-message subject, JSON shape extraction, regex generation) are not in this convention's scope — they have their own per-recipe shape rules. Scaffold-then-polish applies only to free-prose output from a structured input.

A concrete adoption candidate is `prompts/file-summary.md` extended for multi-paragraph output, or a future `prompts/digest-prose.md` recipe. Existing recipes do not migrate. The convention is OPTIONAL like Conventions 1-4.

## Cross-machine signal: graduating an issue into a recipe

The hit/miss log is single-machine. When a MISS surfaces a task shape this library does not yet cover, the cross-machine path is a `prompt-pattern` issue (`.github/ISSUE_TEMPLATE/prompt-pattern.md`). The template captures the task shape, tier and resolved model, the verbatim prompt and model output, and — when known — the prompt that turned the MISS into a HIT. The diff between broken and working prompt is the calibration signal a maintainer needs to draft a recipe without re-running the original session.

The maintainer (or a future PR-bot) graduates a `prompt-pattern` issue by drafting `prompts/<new>.md` from the working prompt, paired with an `evals/eval-set.json` positive that asserts the trigger surface still fires on the task shape, then closing the issue with a link to the merging PR. Every recurring miss becomes both a test case and a fix, instead of evaporating after one conversation. Issues that name an existing recipe but flag a new failure mode update that recipe's `## Calibration notes` rather than spawning a new file.

## Current recipes

Each recipe is tagged for portability, following the engine / environment / flavor split in [ADR 0013](../docs/adr/0013-portable-recipes-flavor-profile.md). A recipe tagged universal is a generic structure, extraction, or mechanical-transform shape — summarisation, structured-field extraction, grounding, em-dash substitution — whose output has a near-ground-truth correct answer, so a new adopter can use it as shipped. A recipe tagged taste-calibrated additionally bakes in the maintainer's judgment about what good output looks like — subject-length ceilings, conventional-commit vocabulary, anti-padding blocklists, prose-over-bullets voice, reply tone — distilled from this project's own MISS history, so it will read as mis-calibrated to someone with different preferences.

The taste-calibrated recipes are the ones a new install should recalibrate; the universal ones rarely need it. `commit-message.md` is the worked proof of the reset path: its subject ceiling and type vocabulary are lifted out of the prompt into a per-user flavor profile that `scripts/derive-flavor.sh` generates from your own `git log` and `scripts/load-flavor.sh` resolves over the shipped defaults (see ADR 0013). `scripts/onboard.sh` wraps that derive/confirm/write loop into a single interactive command — it presents each derived value for confirm-or-edit and writes the profile (plus the `init.sh` routing override) only on explicit confirmation. For a recipe that is not yet flavor-parameterised, the lightest reset is to copy it, swap its Wrong/Correct anchors and voice directives for examples drawn from your own best work, then run `scripts/delegate-feedback.sh hit|miss` over a few sessions — the same hit/miss loop that calibrated these recipes for the maintainer — until the new calibration holds.

- `commit-message.md` (taste-calibrated) — drafting a git commit message from a staged diff and recent log examples.
- `pr-description.md` (taste-calibrated) — drafting a GitHub PR description from a diff stat and a recent merged-PR body.
- `pr-title.md` (taste-calibrated) — drafting one conventional-commit PR title (≤72 chars) synthesised across a branch's commit subjects. Title-only sibling of `pr-description.md` (which drafts the body); not subject to that recipe's 35B/80B `flaky_on_models` stall, and its `subject_max: 72` capability check pairs with the ADR 0020 escalation gate.
- `summarise-diff.md` (universal) — short bullet summary of a git diff focused on user-visible changes.
- `pr-review-reply.md` (taste-calibrated) — one-sentence reply under a PR/MR inline comment after applying or declining the fix.
- `release-note.md` (taste-calibrated) — drafting one CHANGELOG / release-body bullet for a merged PR.
- `summarise-issue.md` (universal) — timeline-style summary of a long GitHub issue, MR thread, or CI log.
- `file-summary.md` (universal) — one-sentence summary of a single document (ADR, analysis, design doc) for a link-index or digest.
- `polish-reply.md` (taste-calibrated) — tighten a multi-paragraph maintainer reply for concision while preserving the opener, closer, and every technical claim verbatim.
- `em-dash-removal.md` (universal) — substitute every em-dash in prose with the most natural alternative (period, comma, semicolon, parens) without expanding contractions or collapsing parenthetical lists.
- `ci-log-triage.md` (universal) — five-field structured triage of a CI / build failure log (FAILURE_TYPE / JOB / STEP / ROOT_CAUSE / NEXT_STEP) from a pre-filtered `gh run view --log-failed` slice. The prototypical input-digestion recipe — per-call token savings dominate output-bounded recipes by 10-100×.
- `roadmap-entry.md` (taste-calibrated) — one heading plus 1-2 flowing-prose paragraphs drafting a single "shipped" entry for a long-running project plan / roadmap file, anchored by a verbatim recent entry and a structured fact list (PR numbers, squash hashes, dates, per-PR shipped summaries).
- `plan-section-intro.md` (taste-calibrated) — one paragraph forward-looking intro for a long-running project plan / roadmap phase, anchored by a verbatim style anchor and a structured fact list. Sibling to `roadmap-entry.md` (which targets past-tense shipped entries).
- `roadmap-status.md` (taste-calibrated) — 1-2 flowing-prose paragraphs drafting a forward-looking "what's next" status across a plan's open items (most-actionable → gated → unstarted → later), anchored by a verbatim style anchor and a priority-ordered fact list. Multi-item sibling of `roadmap-entry.md` (past-tense shipped entries) and `plan-section-intro.md` (single-phase intro); tracks the supplied facts faithfully rather than rephrasing them.
- `doc-section.md` (taste-calibrated) — one short paragraph of guidance for a technical-doc section, grounded in a bullet list of facts; ships v5-style hard rules (keyword-triggered closing-recap deletion) drawn from issue #132's repeated MISS pattern.
- `jira-ticket-description.md` (taste-calibrated) — 2-3 sentence Jira ticket description rewritten from a source paragraph; ships the verbatim-preservation directive, the British-spelling glossary guard, the comma-coordinated no-merge rule, and the closing-sentence opener blocklist.
- `presentation-slide-prose.md` (taste-calibrated) — 2-4 sentence narrative paragraph for a slide given a title + fact list; ships a list-completeness REFUSE hatch and the sharpened anti-padding directive. Parallel-invocation safe.
- `semantic-search.md` (universal) — rank N files by cosine similarity against a query embedding. Shell-pipeline recipe (wraps `scripts/semantic-search.sh`, not `delegate.sh --recipe`) — unlocks the "find the doc that mentions X" pattern without reading every file. Uses the embedding tier via `scripts/embed.sh`.
- `bulk-file-summary.md` (universal) — one-line description per file for a batch of N files (5-50 typical). Per-file loop variant of `file-summary.md`; each delegation stays independently small to fit the prose-tier ceiling per issue #110. Adds a cross-file-relationship guard so the model doesn't invent links between batch siblings. Useful when orienting in a new repo or area of an existing one.
- `long-thread-distillation.md` (universal) — three-section structured distillation of a long PR / issue / MR thread into outstanding action items, blockers, and current consensus. Action-oriented complement to `summarise-issue.md` (timeline format); picks the same input shape but emits the "where does this stand right now" view rather than the "how did we get here" view. Most likely trigger surface is `/address-pr-comments` on a thread with many prior rounds of review.
- `ground-check.md` (universal) — closed-form quote-finder grounding check over the AGENT'S OWN draft claims (not user content): given a numbered CLAIMS list and an EVIDENCE block, returns `SUPPORTED`/`CONTRADICTED` with a verbatim quote or `NOT-STATED`, and a deterministic substring post-check downgrades fabricated-quote verdicts to `UNVERIFIED`. A verification "second-brain" for catching overreach before asserting done/fixed or publishing fact-stating prose. Reasoning-tier, strictly advisory (never a gate), excludes arithmetic and judgment; `SUPPORTED` is a quote-existence certificate, not a truth certificate. Graduated 2026-06-01 on the reasoning tier at 0.9722 (the C6 qualifier-drop case is measured-but-not-gated — see the recipe's Calibration notes).
- `maintainer-reply.md` (taste-calibrated) — drafting a short outbound maintainer reply (PR-review comment, issue status comment, or diagnostic one-liner) from facts: one sentence of specific praise or the confirmed cause, then exactly one question/ask, then an optional warm sign-off. Bakes in the anti-instruction-echo guard (facts on stdin, the ask passed as a topic not an imperative) from issue #283. Drafts from scratch, unlike `polish-reply.md` (tightens an existing draft) and `pr-review-reply.md` (the PR author's one-line "Applied in `<hash>`").
- `github-issue-body.md` (taste-calibrated) — drafting the body of a *new* GitHub issue from facts, using a caller-supplied ordered set of markdown section headings. Distinct from `pr-description.md` (drafts from a diff) and `maintainer-reply.md` (a comment, not a body). Pins the caller's headings so the prose tier can't fall back to a generic bug template, and ships the honest-absence + verbatim-identifier guards. Paired with the boundary hook's `issue-create` branch (`gh issue create --body`), which previously had no matching recipe.
- `bulk-classify.md` (universal) — classifying N items (issues, TODOs, log lines) into a caller-supplied *fixed* category set, one structured line per item. Distinct from `ci-log-triage.md` (single log into five fields) and `miss-theme-cluster.md` (induces themes rather than assigning a fixed set). Ships the verbatim-category, one-line-per-item-in-order, and closed-list escape-hatch guards. Reasoning tier.
- `release-announcement.md` (taste-calibrated) — drafting the warm narrative intro for a release announcement (one or two flowing-prose paragraphs, no headings/bullets) from grouped highlights. Complements `release-note.md` (a single CHANGELOG bullet): this writes the opening narrative, that writes the per-change bullets. Ships the no-puffery, no-greeting, verbatim-number, and no-em-dash house-style guards.
- `miss-theme-cluster.md` (universal) — grouping a flat list of failure reasons (the metrics log's MISS reasons, QA defect notes) into 3-5 induced themes, each named with one verbatim example. The recipe that dogfoods the skill's own calibration loop. Kept inside scope by the at-least-two-reasons floor, the verbatim-quote-per-theme requirement, and the describe-not-explain rule, so it summarises the supplied reasons rather than reasoning beyond them; the most borderline recipe in the library and flagged as such in its calibration notes.

- `fix-with-test.md` (universal) — turn a single source file plus a failing pytest into a minimal SEARCH/REPLACE patch (or an honest `REFUSE:` line). The only recipe with a hard oracle: the patch is verified by re-running the test via `apply-and-test.sh`, not trusted on the model's say-so. Drives `scripts/fanout-patch.sh`'s fan-out loop.

## What this library does NOT adopt

Three patterns recur in public prompt libraries and have been deliberately rejected for this skill. Documenting the rejection rationale here so future contributors do not drift toward the public idiom unknowingly. External citations in this file are intentional and pre-allowlisted by scope (see `scripts/validate-skill-content.sh` — CI / hooks only scan `SKILL.md`).

### "You are an expert X" persona prompts

Persona prompts ("You are an expert X", "Act as a senior Y") are a public-idiom default in agent prompt libraries. Zheng et al. ([arXiv 2311.10054](https://arxiv.org/html/2311.10054v3), EMNLP Findings 2024) tested personas across four families of LLMs on 2,410 factual questions and found that adding personas in system prompts does not improve model performance compared to no-persona baselines; automatically selecting beneficial personas performed no better than random. The Wharton replication ["Playing Pretend: Expert Personas Don't Improve Factual Accuracy"](https://gail.wharton.upenn.edu/research-and-insights/playing-pretend-expert-personas/) confirmed the null effect on knowledge-retrieval tasks. This skill exclusively targets local small models for closed-form work (commit messages, structured extraction, classification) — the task shape the literature has measured persona effects on — so adopting persona openers wholesale would add tokens without a measurable quality uplift. Domain-context priming (declarative input-naming, e.g. "The input is a unified diff hunk") is distinct from persona and is validated separately — see Phase 12 Track A (#160) for the local empirical test.

The Jekyll and Hyde study ([arXiv 2408.08631](https://arxiv.org/abs/2408.08631), August 2024) extends the null-effect evidence with a stronger finding: persona prompts actively degrade reasoning performance on seven of twelve datasets tested on Llama3. The harm measurement is on reasoning tasks specifically rather than on this skill's closed-form shapes (summarisation, classification, extraction), but the result strengthens the existing rejection from "inert" to "inert and occasionally harmful" — a stronger argument than the null result alone for declining to adopt persona openers wholesale.

### Microsoft Prompty wholesale schema

Microsoft [Prompty](https://github.com/microsoft/prompty) is a format-cousin to this library's recipes (markdown body, templated variables). Its wholesale schema (YAML frontmatter, Jinja, VS Code extension) is calibrated for VS Code Copilot integration that this skill does not consume. The reformat cost of rewriting fifteen existing recipes (re-running every scorer, re-dogfooding each recipe across multiple sessions) is real, and the persona / prompt-engineering literature does not predict a quality uplift for small models from adopting the schema wholesale. Heavier YAML features (nesting, anchors, flow style) exceed what `delegate.sh`'s simple line-based extraction can handle and stay rejected on portability grounds.

### fabric's "produce N items at M words each" item-count discipline

[fabric](https://github.com/danielmiessler/fabric) ships 255 patterns; many specify caps like "20-50 ideas at 16 words each". The T4 calibration history captured in `prompts/commit-message.md` calibration notes and `experiments/score-t4.sh` PADDING_REGEXES shows that the small-model failures this skill actually sees are shape failures (participial padding, declarative restating), not count failures. Importing fabric's count discipline would invite the model to fabricate-to-fill the prescribed item count, creating a new MISS class the calibration loop would then have to absorb — net negative. The skill's existing `## Expected output shape` block already encodes structural limits (e.g., commit-message's 72-char subject cap) without inviting the fabricate-to-fill failure mode.

The companion list of patterns this library DOES adopt lives in Track B (#161), which imports only the flat `key: type` `inputs:` block convention from Prompty for declarative type validation.

## Related

- `SKILL.md` "Recipes" section references this directory and tells the agent when to consult a recipe.
- `scripts/delegate.sh` is the wrapper that recipes feed prompts into.
- `scripts/delegate-feedback.sh hit|miss` records whether the output was kept; `scripts/metrics-summary.sh` rolls up calibration over time.
- `evals/eval-set.json` paraphrase positives keep the trigger surface aligned with recipe coverage.
