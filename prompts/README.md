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

## Current recipes

- `commit-message.md` — drafting a git commit message from a staged diff and recent log examples.
- `pr-description.md` — drafting a GitHub PR description from a diff stat and a recent merged-PR body.
- `summarise-diff.md` — short bullet summary of a git diff focused on user-visible changes.
- `pr-review-reply.md` — one-sentence reply under a PR/MR inline comment after applying or declining the fix.

## Related

- `SKILL.md` "Recipes" section references this directory and tells the agent when to consult a recipe.
- `scripts/delegate.sh` is the wrapper that recipes feed prompts into.
- `scripts/delegate-feedback.sh hit|miss` records whether the output was kept; `scripts/metrics-summary.sh` rolls up calibration over time.
- `evals/eval-set.json` paraphrase positives keep the trigger surface aligned with recipe coverage.
