# Prompts library

This directory holds calibrated prompt recipes for tasks that recurringly fit the `delegate-to-ollama` skill's trigger surface — drafting, summarising, classifying, extracting, rewriting. Each file encodes a task shape that has been empirically validated against a local prose-tier or code-tier model (defaults from `scripts/pick-model.sh`) and produced HIT-class output (verbatim or near-verbatim usable, per `scripts/delegate-feedback.sh`).

## Why this directory exists

Small / local models (≤80B) need much more handholding than Opus-class. Abstract style descriptors like "match the project's terse style" or "concise commit message" reliably yield bullet lists when the project's recent style is flowing prose — the model defaults to whatever shape is most common in its training, not what the calling agent imagined. The fix that consistently turns MISS into HIT in real sessions is verbatim-example anchoring plus explicit anti-hallucination guards.

Rather than rediscover that fix every conversation, the proven prompts live here as versioned recipes. Each recipe ships with the skill so every install (Claude Code plugin, AAIF symlink, `npx skills add`) inherits the calibration. Recipes evolve append-style: every recurring HIT graduates to a recipe entry; every MISS that names a missing recipe gets one filed.

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

## Cross-machine signal: graduating an issue into a recipe

The hit/miss log is single-machine. When a MISS surfaces a task shape this library does not yet cover, the cross-machine path is a `prompt-pattern` issue (`.github/ISSUE_TEMPLATE/prompt-pattern.md`). The template captures the task shape, tier and resolved model, the verbatim prompt and model output, and — when known — the prompt that turned the MISS into a HIT. The diff between broken and working prompt is the calibration signal a maintainer needs to draft a recipe without re-running the original session.

The maintainer (or a future PR-bot) graduates a `prompt-pattern` issue by drafting `prompts/<new>.md` from the working prompt, paired with an `evals/eval-set.json` positive that asserts the trigger surface still fires on the task shape, then closing the issue with a link to the merging PR. Every recurring miss becomes both a test case and a fix, instead of evaporating after one conversation. Issues that name an existing recipe but flag a new failure mode update that recipe's `## Calibration notes` rather than spawning a new file.

## Current recipes

- `commit-message.md` — drafting a git commit message from a staged diff and recent log examples.
- `pr-description.md` — drafting a GitHub PR description from a diff stat and a recent merged-PR body.
- `summarise-diff.md` — short bullet summary of a git diff focused on user-visible changes.
- `pr-review-reply.md` — one-sentence reply under a PR/MR inline comment after applying or declining the fix.
- `release-note.md` — drafting one CHANGELOG / release-body bullet for a merged PR.
- `summarise-issue.md` — timeline-style summary of a long GitHub issue, MR thread, or CI log.
- `file-summary.md` — one-sentence summary of a single document (ADR, analysis, design doc) for a link-index or digest.
- `polish-reply.md` — tighten a multi-paragraph maintainer reply for concision while preserving the opener, closer, and every technical claim verbatim.
- `em-dash-removal.md` — substitute every em-dash in prose with the most natural alternative (period, comma, semicolon, parens) without expanding contractions or collapsing parenthetical lists.
- `ci-log-triage.md` — five-field structured triage of a CI / build failure log (FAILURE_TYPE / JOB / STEP / ROOT_CAUSE / NEXT_STEP) from a pre-filtered `gh run view --log-failed` slice. The prototypical input-digestion recipe — per-call token savings dominate output-bounded recipes by 10-100×.
- `roadmap-entry.md` — one heading plus 1-2 flowing-prose paragraphs drafting a single "shipped" entry for a long-running project plan / roadmap file, anchored by a verbatim recent entry and a structured fact list (PR numbers, squash hashes, dates, per-PR shipped summaries).
- `doc-section.md` — one short paragraph of guidance for a technical-doc section, grounded in a bullet list of facts; ships v5-style hard rules (keyword-triggered closing-recap deletion) drawn from issue #132's repeated MISS pattern.
- `jira-ticket-description.md` — 2-3 sentence Jira ticket description rewritten from a source paragraph; ships the verbatim-preservation directive, the British-spelling glossary guard, the comma-coordinated no-merge rule, and the closing-sentence opener blocklist.
- `presentation-slide-prose.md` — 2-4 sentence narrative paragraph for a slide given a title + fact list; ships a list-completeness REFUSE hatch and the sharpened anti-padding directive. Parallel-invocation safe.

## What this library does NOT adopt

Three patterns recur in public prompt libraries and have been deliberately rejected for this skill. Documenting the rejection rationale here so future contributors do not drift toward the public idiom unknowingly. External citations in this file are intentional and pre-allowlisted by scope (see `scripts/validate-skill-content.sh` — CI / hooks only scan `SKILL.md`).

### "You are an expert X" persona prompts

Persona prompts ("You are an expert X", "Act as a senior Y") are a public-idiom default in agent prompt libraries. Zheng et al. ([arXiv 2311.10054](https://arxiv.org/html/2311.10054v3), EMNLP Findings 2024) tested personas across four families of LLMs on 2,410 factual questions and found that adding personas in system prompts does not improve model performance compared to no-persona baselines; automatically selecting beneficial personas performed no better than random. The Wharton replication ["Playing Pretend: Expert Personas Don't Improve Factual Accuracy"](https://gail.wharton.upenn.edu/research-and-insights/playing-pretend-expert-personas/) confirmed the null effect on knowledge-retrieval tasks. This skill exclusively targets local small models for closed-form work (commit messages, structured extraction, classification) — the task shape the literature has measured persona effects on — so adopting persona openers wholesale would add tokens without a measurable quality uplift. Domain-context priming (declarative input-naming, e.g. "The input is a unified diff hunk") is distinct from persona and is validated separately — see Phase 12 Track A (#160) for the local empirical test.

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
