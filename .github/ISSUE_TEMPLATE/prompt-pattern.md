---
name: Prompt pattern (recurring MISS)
about: A delegation that didn't produce HIT-class output and isn't covered by an existing recipe
title: 'prompt-pattern: <short task shape>'
labels: prompt-pattern
assignees: ''
---

## Task shape

One or two sentences describing what you asked the skill to do. Be concrete about the input (a staged diff, a long issue thread, an error log) and the output you expected (one-paragraph summary, JSON, a single bullet). If a recipe in `prompts/` looks adjacent but didn't fit, name it.

## Tier and model

The tier you invoked (`code` / `prose` / `reasoning` / `long-context`) and the resolved model name from `bash scripts/pick-model.sh <tier>`. If you overrode the routing with `OLLAMA_MODEL=...` or a personal `config.sh`, say so.

## Prompt sent

The exact prompt text or template you used, including any context the agent injected before it. If the prompt came from a recipe with `--var` substitutions, paste the substituted result rather than the template.

```text
<paste prompt here>
```

## Model output

The verbatim model output. Do not paraphrase — calibration depends on the failure mode being legible.

```text
<paste output here>
```

## Why it was a MISS

What the agent had to do to make the output usable: rewrite from scratch, restructure bullets to prose, strip a hallucinated PR number, swap a wrong verb, drop a fabricated section. The more specific the failure mode, the easier the recipe is to draft. The four common categories are shape (bullets vs prose, JSON shape), tone (terseness, project voice), hallucination (invented identifiers, fake severity), and omission (missing the actual ask).

## Suggested fix

If you already found a prompt that turned the MISS into HIT, paste it here. A recipe ships best when the issue includes both the broken prompt and the working one — the diff is the calibration signal. If you haven't found a fix yet, leave this blank and the maintainer (or a future PR-bot) will iterate.

## Metrics row (optional)

The `ts` field of the relevant line(s) in `~/.claude/skills/delegate-local/metrics.jsonl`. Lets the maintainer cross-check timing, output size, and any paired `delegate-feedback.sh miss` row.
