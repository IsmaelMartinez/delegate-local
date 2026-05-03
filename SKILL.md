---
name: delegate-to-ollama
description: Use this skill to offload non-reasoning text work to locally-installed Ollama models via `ollama run`, saving Anthropic API tokens and keeping content on-device. MUST use whenever the user asks to summarise a log/diff/file/PR, draft a commit message/changelog/release note, triage or classify many items, extract structured fields from free text, skim many files for a one-liner, rewrite or reformat prose, anonymise or redact text, convert between markup formats (YAML↔JSON, markdown→HTML), generate regex from description, or stub docstrings — any "gather context once, send one prompt, return text" pattern. MUST also use when the user mentions running locally, on-device, offline, saving tokens, privacy, Ollama, or a local model. MUST also use when the user has previously asked to "delegate where it fits", "auto-delegate", "route to ollama as appropriate", or similar — once that intent is set in a conversation, default to delegating any subsequent matching task without re-confirming. Do NOT use for code correctness review, architectural decisions, debugging or tracing errors, implementing features, or any task whose output triggers a destructive or shared-state action without review. Do NOT use for open-ended "find anything interesting / suggest improvements / what should we worry about" prompts that ask the model to surface things not in the input — those invite fabrication and are the highest-volume failure mode.
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
- Draft a commit message, changelog entry, or release note for a single-file mechanical change.
- Classify or triage N items (relevant/noise, bug/feature).
- Closed-form classification with an explicit, finite option set (e.g. "high|medium|low|info" severity, "REAL|FP" filter against a stated allowlist). The 2026-05-03 retrospective measured 5/5 reps perfect on FP-filter when the allowlist rule was explicit and a one-shot example was included.
- Compose structured prose from a fixed list of items (PR comment from a findings list, release-note bullets from a changelog block). The 2026-05-03 retrospective measured 3/3 PASS on PR-comment composition once the prompt forbade placeholder substitution explicitly.
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

Three steps, in order, every time: **gather → delegate → verify**.

1. **Gather** the context you can fit in a short prompt (≤ 8k tokens; local models degrade above that).
2. **Delegate** with a constrained prompt that asks for an exact output shape.
3. **Verify** every specific claim the model returns against the actual files before acting on it. Treat the model's output as a hypothesis, not a finding.

Use `scripts/delegate.sh <tier> "<prompt>"` — it resolves the tier to a model, runs `ollama run` with thinking suppressed (`--think=false` by default; override with `DELEGATE_THINK=true` if reasoning chains genuinely help), strips spinner ANSI bytes from the captured output, and appends one JSON line per invocation to `~/.claude/skills/delegate-to-ollama/metrics.jsonl` for `scripts/metrics-summary.sh` to roll up later.

### Discipline for closed-format work

The 2026-05-03 retrospective (`experiments/sessions/2026-05-03-security-review-delegation/`) measured the same 4-sub-task suite with and without prompt discipline. Without discipline (single shot, thinking on, no example, four sub-tasks bundled in one prompt) the local model scored 1.5 of 4. With discipline (thinking off, one-shot example, atomic single-sub-task call, explicit qualifier rules) qwen3-coder-next:latest scored 3.6 of 4 — within 9% of Haiku's 3.95. The same four practices recur in 2026 practitioner reports:

- **One sub-task per call.** Bundling multiple sub-tasks in one prompt collapses the "single atomic output" property that makes local models reliable. If you have four things to classify, four `delegate.sh` calls are more reliable than one prompt that asks for four answers.
- **Include a one-shot example in the prompt.** Local models infer the output shape much better from one concrete `Example: ... → output: ...` block than from prose description alone. The example must use a different finding/item from the actual input so it doesn't leak the answer.
- **Make qualifier rules explicit.** When a finding text says "this is intentional in single-user dev contexts", local models tend to override that qualifier with prior beliefs (CVSS conventions, "code execution is always high"). Spell out in the prompt: *"if the input says behaviour X is intentional in context Y, severity reflects design intent, not vulnerability class"*.
- **Thinking off is the default.** delegate.sh now passes `--think=false` automatically. The chain-of-thought tax for closed-format work showed up as both alarmist drift on classification and direct format failures (placeholder substitution).

```bash
git diff HEAD~5 | bash ~/.claude/skills/delegate-to-ollama/scripts/delegate.sh prose \
  "Summarise this diff in 3 bullets focused on user-visible changes."
```

```bash
cat build.log | bash ~/.claude/skills/delegate-to-ollama/scripts/delegate.sh reasoning \
  "List only the lines indicating test failures. One per line, no commentary."
```

Always report the model used ("Delegated to qwen3.6:35b-a3b-q8_0 (prose tier)") so a bad answer is visible to the user. For long inputs, use the `long-context` tier. To opt out of metrics for a single invocation, set `DELEGATE_TO_OLLAMA_NO_METRICS=1`. To resolve the model without delegating (e.g., for inspection), call `pick-model.sh` directly.

## Prompt scope — closed vs open

Local models reliably produce closed-form output (extract, classify, restructure) but invent findings when asked open-ended questions (find loose ends, suggest improvements, what should we worry about). In one measured session, an 80B model produced four confident concerns from a 10-commit diffstat plus subject lines; all four were wrong on verification (claimed missing automation that existed, claimed missing test coverage that existed, etc.).

Closed prompts that work well:
- "List the lines in this log that match `<pattern>`."
- "Extract `{name, party, position}` as JSON from each candidate block."
- "Classify each TODO as P0/P1/P2."
- "Does this YAML match this expected shape? Output CLEAN or list deviations."

Open prompts that produce hallucination:
- "Find anything interesting in this diff."
- "What patterns or loose ends do you see?"
- "Suggest improvements."
- "Is there something we should worry about?"

If the answer would be valuable specifically because the model is *reasoning beyond what is in the prompt*, that is the wrong job for a local model. Do it yourself or ask Claude.

## Tier → model routing

`pick-model.sh <tier>` resolves a tier to the best installed model at runtime. Do **not** hardcode model names in calls — the installed set changes.

| Tier               | Use for                                                          |
|--------------------|------------------------------------------------------------------|
| `code`             | Code summaries, diff explanations, renaming.                     |
| `prose`            | Commit messages, docs, release notes.                            |
| `reasoning`        | Structured extraction, classification, triage.                   |
| `long-context`     | Large logs, many-file scans, big diffs.                          |
| `vision`           | Image OCR, screenshot triage, visual description.                |
| `embedding`        | Local semantic search ("which doc talks about X").               |
| `premium-general`  | Explicit opt-in for verbose enumeration; **not** a quality upgrade over `prose` (see baseline). |
| `reasoning-vision` | Structured extraction or classification from screenshots.        |

The `prose` tier is for *generating* prose (commit messages, summaries), not for *inferring* about prose. For analytical work over a diff or log, use `reasoning` even if the input is text-heavy. See `experiments/results/` for measured accuracy by tier and task type.

The `premium-general` tier exists for tasks where the user has explicitly chosen a larger model. Do **not** route prose work to it by default — the 2026-05-01 baseline measured `qwen3.5:122b` as the worst T3 performer in the matrix (citation rate 0.16, vs 0.71 for the 31B `gemma4` and 0.36 for the default `qwen3.6:35b`), with high claim volume that ignored the prompt's 4-claim cap. Bigger does not mean better; verify outputs from this tier especially carefully.

Preference order per tier lives in `scripts/pick-model.sh`. Edit that file (not the skill body) when your installed models change.

### Call shape per tier

`code`, `prose`, `reasoning`, `long-context`, and `premium-general` all use the standard `delegate.sh <tier> "<prompt>"` wrapper — context on stdin, prompt as the argument, response on stdout, metrics appended to the JSONL.

`vision` and `reasoning-vision` resolve a model name but go through the Ollama HTTP API (`POST /api/generate` with a base64-encoded `images` array) — Ollama 0.21's `ollama run` CLI does not expose an `--image` flag. The API runs on the same daemon as `ollama run`, so no extra setup is needed:

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh vision)
IMG_B64=$(base64 < /tmp/screen.png | tr -d '\n')
curl -s -H "Content-Type: application/json" http://localhost:11434/api/generate \
  -d "$(jq -n --arg m "$MODEL" --arg p "Describe what is in this screenshot." --arg i "$IMG_B64" \
        '{model:$m, prompt:$p, images:[$i], stream:false}')" \
  | jq -r '.response'
```

`embedding` uses `POST /api/embed` for the same reason — `ollama` has no `embed` subcommand:

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh embedding)
curl -s -H "Content-Type: application/json" http://localhost:11434/api/embed \
  -d "$(jq -n --arg m "$MODEL" --arg t "the text to embed" '{model:$m, input:$t}')" \
  | jq '.embeddings[0]'
```

Both bypass `delegate.sh` because the wrapper currently assumes text-in / text-out via `ollama run`. Folding image and embed call shapes into the wrapper is future work — track it on the roadmap before doing it, since both shapes need different metrics and different output handling than the current pipe.

## Failure modes — concrete examples

These are real failure modes observed in production use, surfaced as warnings when you find yourself doing them.

- **The "find anything interesting" prompt.** Producing fabricated concerns is the highest-volume failure. If your prompt asks the model to surface things that are not in the input, expect invented findings. Constrain it to listing what *is* present, in a fixed shape, then verify.
- **Asking a reasoning model to verify its own claim.** The model cannot read your filesystem. If it says "X probably exists in file Y", that is a hypothesis. Run `grep` yourself.
- **Treating long output as confidence.** Reasoning models emit chain-of-thought, which can mask a wrong answer in plausible-sounding scaffolding. Look at the final verdict, not the volume.
- **Hardcoding model names in calls.** Models drift out every few weeks. Always go through `pick-model.sh <tier>`.
- **Putting secrets into the prompt.** Local is safer than cloud, but the prompt still ends up in shell history and ollama logs.
- **Bigger model = better answer.** Not always. The largest installed model (80B) was the worst performer on inference tasks in measured runs; an 11GB reasoning model beat it. Prefer the smallest model sufficient — see `scripts/audit-models.sh` for upgrade signals.
- **Cross-PR / multi-feature commit message drafting.** Asking the prose tier to summarise a diff that spans many commits or unrelated features invites fabrication — the model pattern-matches on the markdown text and invents which feature shipped where. In one observed session, a 35B prose-tier model produced a confident 4-paragraph commit message claiming code routing changes that the diff did not contain, and dropping a category ("crypto") that the diff explicitly mentioned. Commit-message drafting is in the Fits list only for *single-file mechanical* changes; for multi-feature or cross-PR summaries, do it yourself.

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
