# Prompts library

This directory holds the recipes for the one shape the skill serves since ADR 0035: a large input the agent has not read, piped to a local model for a short answer anchored to it. Three recipes remain, all extraction-shaped, which ADR 0023 found far more reliable on local models than taste-calibrated prose:

- `summarise-issue.md` (reasoning tier): a timeline-style status of a long GitHub issue, MR or PR thread, or CI log, with every bullet tied to a date, comment or log line.
- `bulk-classify.md` (reasoning tier): one structured line per item, assigning each to exactly one category from a caller-supplied fixed set.
- `file-summary.md` (prose tier): a one-sentence summary of a single document, one call per file when summarising a directory.

The ten writing and code recipes (commit-message, pr-description, maintainer-reply, maintainer-review-reply, pr-review-reply, github-issue-body, doc-section, release-announcement, code-draft and fix-with-test) were archived by ADR 0035, and ten more by #568 before them. All of them, with their calibration logs, are recoverable from commit `a00b2e9`. Do not add a recipe without a new ADR that answers ADR 0035's signposts.

## How a recipe is structured

Each `<task>.md` file has a YAML frontmatter block (`tier:`, an optional `inputs:` block, optional `checks:`) and these sections:

```
# <task name>

## When to use
The task shape, and what is out of scope.

## Context to gather first
The inputs the agent collects before the call, and how to keep them small.

## Prompt template
The exact text sent to the model, in a fenced block, with {{name}}
placeholders and the guards distilled from past misses.

## Variables
One bullet per {{name}} placeholder.

## Invocation
A `bash scripts/delegate.sh --recipe <name> --var k=v ...` example, with the
input piped on stdin and every --var passed as a literal value.

## Expected output shape
What a usable answer looks like, so the agent can check it before acting.

## Calibration notes
A one-line pointer to docs/calibration/<task>.md, the dated history.
```

## How `--recipe` and `--var` work

`scripts/delegate.sh --recipe NAME [--var key=value ...] ["<prompt>"]` loads `prompts/<NAME>.md`, extracts the first fenced block under `## Prompt template`, substitutes each `{{key}}` with the matching `--var` value and `{{stdin}}` with the piped input, and sends the result. An unsubstituted placeholder exits 2, because a partly filled template usually means a missed input. The recipe's `tier:` decides the route; `--tier` overrides it. A recipe may declare its inputs as flat `key: type` pairs (`integer`, `string`, and `?` for optional) in an `inputs:` block, and `delegate.sh` type-checks each `--var` before contacting the model; an omitted optional input collapses to the empty string.

## Conventions that held

Contrastive anchors beat enumeration. Listing more forbidden phrases stopped binding after the first few; a Wrong/Correct pair showing the same idea in the wrong and the right shape moved the model where the list did not. Write the pair in subject matter the recipe's callers do not touch, and as an angle-bracket skeleton (`<date>: <one-line fact>`) rather than a fluent sentence, because on long inputs the model returns a fluent example verbatim.

State hard rules with keyword triggers and a priority order for any fixed output set; an example alone does not move the model's prior. Offer a `REFUSE:` line for inputs that do not contain the answer, so absence is reported rather than invented.

## What this library does NOT adopt

Three patterns recur in public prompt libraries and were rejected for this skill. External citations in this file are intentional; only `SKILL.md` is held to the URL allowlist.

### "You are an expert X" persona prompts

Zheng et al. ([arXiv 2311.10054](https://arxiv.org/html/2311.10054v3), EMNLP Findings 2024) tested personas across four model families on 2,410 factual questions and found no improvement over no-persona baselines; the Wharton replication ["Playing Pretend: Expert Personas Don't Improve Factual Accuracy"](https://gail.wharton.upenn.edu/research-and-insights/playing-pretend-expert-personas/) confirmed the null effect. The Jekyll and Hyde study ([arXiv 2408.08631](https://arxiv.org/abs/2408.08631), August 2024) found personas degrade reasoning on seven of twelve datasets on Llama3. Declarative input-naming ("The input is a CI log") is distinct from a persona and stays allowed.

### Microsoft Prompty wholesale schema

[Prompty](https://github.com/microsoft/prompty) is a format cousin (markdown body, templated variables), but its YAML, Jinja and editor integration exceed what `delegate.sh`'s line-based extraction handles; only the flat `inputs:` block was imported.

### fabric's "produce N items at M words each"

[fabric](https://github.com/danielmiessler/fabric) caps output by item count. The small-model failures this library saw were shape failures (padding, restating), not count failures, and a prescribed count invites the model to fabricate to fill it. `summarise-issue`'s `N_FACTS` is a ceiling the model must stop at, never a quota.

## Related

- `SKILL.md` "Recipes" tells the agent when to use each recipe.
- `scripts/delegate.sh` is the wrapper the recipes feed.
- `tests/test-prompts-library.sh` enforces the structure above.
- `docs/learnings.md` keeps what the archived recipes taught.
