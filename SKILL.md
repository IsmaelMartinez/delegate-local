---
name: delegate-to-ollama
description: Use this skill to offload non-reasoning text work to locally-installed Ollama models via `ollama run`, saving Anthropic API tokens and keeping content on-device. MUST use whenever the user asks to summarise a log/diff/file/PR, draft a commit message/changelog/release note, triage or classify many items, extract structured fields from free text, skim many files for a one-liner, rewrite or reformat prose, anonymise or redact text, convert between markup formats (YAML↔JSON, markdown→HTML), generate regex from description, or stub docstrings — any "gather context once, send one prompt, return text" pattern. MUST also use when the user mentions running locally, on-device, offline, saving tokens, privacy, Ollama, or a local model. MUST also use when the user has previously asked to "delegate where it fits", "auto-delegate", "route to ollama as appropriate", or similar — once that intent is set in a conversation, default to delegating any subsequent matching task without re-confirming. Do NOT use for code correctness review, architectural decisions, debugging or tracing errors, implementing features, or any task whose output triggers a destructive or shared-state action without review.
---

# Delegate to Ollama

Offload non-agentic text tasks to locally-installed Ollama models via `ollama run`, saving API tokens and keeping content on-device. Local models are strong summarisers and weak reasoners — scope accordingly.

**Core insight (from local-brain):** you do not need a framework. You need `context | ollama run model`.

## Operating mode

Default to auto-delegate. When this skill is loaded into the conversation and the user's task matches the Fits list below, delegate immediately without asking permission. Report which model handled it ("Delegated to qwen3.6:35b-a3b-q8_0 (prose tier)") so the user can spot a bad answer and override. Do not ask "should I delegate this?" — the skill being loaded means yes by default. Re-confirm only if the task is borderline or the input contains content the user explicitly flagged as sensitive.

If the user says any of: "delegate where it fits", "use ollama where appropriate", "auto-delegate", "route to local where it makes sense", or similar — treat that as durable consent for the rest of the conversation: from that point on, every matching task goes through `ollama run` without further prompting.

## When to delegate

Fits:
- Summarise a long log, diff, file, or PR description.
- Draft a commit message, changelog entry, or release note.
- Classify or triage N items (relevant/noise, bug/feature).
- First-pass "what does this file do" over many files.
- Extract structured fields (JSON) from free-form text.
- Reformat or rewrite prose.

Do NOT delegate:
- Multi-step reasoning, planning, or tool-calling.
- Tasks needing repo-wide context that does not fit one prompt.
- Code correctness, security, architectural judgements.
- Anything whose output directly triggers a destructive or shared-state action without review.
- The user asked for *your* analysis specifically.

If `ollama` is not on PATH or `ollama list` is empty, do the work yourself and mention why.

## Pattern

Always: gather context, pipe to `ollama run`, report the model used so a bad answer is visible.

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh prose)
git diff HEAD~5 | ollama run "$MODEL" \
  "Summarise this diff in 3 bullets focused on user-visible changes."
```

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh reasoning)
cat build.log | ollama run "$MODEL" \
  "List only the lines indicating test failures. One per line, no commentary."
```

Keep prompts short; local models degrade above ~8k tokens. For long inputs, use the `long-context` tier.

## Tier → model routing

`pick-model.sh <tier>` resolves a tier to the best installed model at runtime. Do **not** hardcode model names in calls — the installed set changes.

| Tier           | Use for                                         |
|----------------|-------------------------------------------------|
| `code`         | Code summaries, diff explanations, renaming.    |
| `prose`        | Commit messages, docs, release notes.           |
| `reasoning`    | Structured extraction, classification, triage.  |
| `long-context` | Large logs, many-file scans, big diffs.         |

Preference order per tier lives in `scripts/pick-model.sh`. Edit that file (not the skill body) when your installed models change.

## Keeping the model set current

Local models drift; better ones ship every few weeks. The audit script uses `llmfit` to compare your installed models against the current HuggingFace catalogue scored for this hardware, and flags uninstalled models that beat the installed leader by 3+ points.

```bash
bash ~/.claude/skills/delegate-to-ollama/scripts/audit-models.sh
```

It prints installed models, shows tier routing, runs `llmfit recommend --use-case <coding|general>` for each tier, and lists suggested pulls with their llmfit composite score (quality + speed + fit + context). It never pulls automatically — you confirm each upgrade. Ollama tags sometimes differ from the HuggingFace name, so verify on https://ollama.com/library before pulling.

Requires `llmfit` and `jq` on PATH. Without llmfit the script still prints routing; the upgrade-check section is skipped with a hint.

When reviewing, the rule from ai-model-advisor applies: prefer the smallest model sufficient for the task. Bigger is not better if a 9GB model handles the prompt in half the time.

To refresh llmfit's model database before auditing: `llmfit update`.

## Red flags — stop and do the work yourself

- You are about to delegate something that requires reading more files.
- You cannot summarise the task in a single prompt ≤ 8k tokens.
- The user will act on the answer without reading it.
- You are unsure whether the model's answer would be correct.
- The task involves secrets or credentials (local is safer, but still avoid putting secrets into any prompt).
