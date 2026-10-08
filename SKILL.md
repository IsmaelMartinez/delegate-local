---
name: delegate-local
description: Use this skill to offload non-reasoning text work to locally-installed models (Ollama or MLX) via `delegate.sh`, keeping content on-device and freeing the main-agent context window. Also saves API tokens, though privacy and context protection, not cost, are the point. MUST use whenever the user asks to summarise a log/diff/file/PR/issue, draft a commit message/changelog/release note, triage or classify many items, extract structured fields from free text, skim many files for a one-liner, or rewrite or reformat prose. MUST also use when the user explicitly asks to delegate, names a local backend or model (Ollama, MLX, "a local model"), wants content kept on-device or offline for privacy, or wants to save API tokens. Bare "run it locally" usually means running the app, server, or tests on the user's machine, so treat "locally" as a delegation signal only with an explicit delegate verb, a named local model, or a keep-it-private reason. MUST also use after the user sets durable auto-delegate intent ("delegate where it fits", "auto-delegate", "route to local where it makes sense"), then delegate each later matching task without re-confirming. Do NOT use for code correctness review, architectural decisions, debugging or tracing errors, implementing features, or any task whose output triggers a destructive or shared-state action without review. Do NOT use for open-ended "find anything interesting / suggest improvements" prompts that ask the model to surface things not in the input — those invite fabrication.
---

# Delegate Local

Offload non-agentic text work to a model running on this machine. The value is privacy (content stays on-device) and context protection (the main-agent window is not spent on paragraph fills); API-token savings are real but small and a side effect. Local models are strong summarisers and weak agents, so scope every call accordingly: you need no framework, only context piped into one prompt.

Paths below are relative to the skill directory (`~/.claude/skills/delegate-local/` on a Claude Code install).

## Operating mode

Default to auto-delegate. When this skill is loaded and the task matches "When to delegate", delegate without asking. Re-confirm only when the task is borderline or the input holds content the user flagged as sensitive. If the user says "delegate where it fits", "auto-delegate", "use ollama where appropriate", "route to local where it makes sense" or similar, treat it as durable consent for the rest of the conversation and delegate every later matching task without prompting.

After every successful call, `delegate.sh` prints a `delegate-meta:` line on stderr (silenced by `DELEGATE_LOCAL_NO_META=1`) with space-separated `key=value` pairs: `model`, `tier`, `backend`, `tokens_local`, `duration_ms`, then `ts` and `id` only when the call wrote its metrics row (not under `DELEGATE_LOCAL_NO_METRICS=1` or after a failed append), and on recipe calls `recipe`, plus `checks_failed=N` (an output check the text still fails after the wrapper's one retry: eyeball that aspect before using it) and `checks_autofixed=N` (a trailing padding clause the wrapper stripped: confirm nothing meaningful went). In your reply, name the model and the local-token count, e.g. "Delegated to qwen3.6:35b-a3b-q8_0 (prose tier), ~578 tokens kept local in 1.4 s." Say "kept local", not "saved from Claude": `tokens_local` is total chars in and out divided by 4, not a billable count.

## When to delegate

Fits:
- Summarise a long log, diff, file, issue or PR thread.
- Draft a commit message, PR description, issue body, review reply, release intro or changelog entry.
- Classify or triage N items into a fixed, stated set of categories.
- Compose structured prose from a fixed list of items (a comment from a findings list, bullets from a changelog block).
- A first-pass "what does this file do" over many files; extract structured fields (JSON) from free text; reformat or rewrite prose.
- One bounded code draft inside your own implementation work, verified by a test you run (see "Supervised code drafts").

Do NOT delegate:
- Multi-step reasoning, planning or tool-calling.
- Tasks needing repo-wide context that does not fit one prompt.
- Code correctness, security or architectural judgements.
- Anything whose output directly triggers a destructive or shared-state action without your review.
- Work the user asked you, specifically, to analyse.
- A commit message or summary spanning many commits or unrelated features: the model invents which change shipped where.

Structure is yours, prose is delegated. Headings, code blocks, links, tables and CLI examples are decisions you own; flowing explanatory paragraphs are what the model fills. A task whose real work is deciding where content belongs (collapsing duplicates, moving sections, replacing a section with a pointer) is not a delegation candidate even though its output is text. Judge density per session as well as per edit: if the session will produce more than about four paragraphs of delegatable prose in total, delegation is the default even when each edit is small.

If no provider is reachable, or none serves a model for the tier, `pick-model.sh` says which of the two on stderr and the call fails; do the work yourself and say why.

## Pattern: gather, delegate, verify

1. Gather the context that fits one short prompt (well under 8k tokens; local models degrade above that).
2. Delegate with a closed prompt that names the exact output shape.
3. Verify every specific claim against the real files before acting on it. The output is a hypothesis, not a finding.

```bash
git diff HEAD~5 | bash scripts/delegate.sh prose \
  "Summarise this diff in 3 bullets focused on user-visible changes."
cat build.log | bash scripts/delegate.sh reasoning \
  "List only the lines indicating test failures. One per line, no commentary."
```

`delegate.sh <tier> "<prompt>"` takes context on stdin, resolves the tier with `pick-model.sh`, and posts to the winning provider's `{base}/chat/completions` with `temperature:0` and thinking off through `chat_template_kwargs` (`DELEGATE_THINK=true` turns it on). The answer is plain text on stdout. Each call appends one row to `~/.local/share/delegate-local/metrics.jsonl` and stores the draft beside it; `DELEGATE_LOCAL_NO_METRICS=1` opts a call out. A long request can take a while, especially the first call to a model that is not loaded yet; if a call runs well past a minute with no output, kill it and split the work into smaller atomic calls.

Single-quote any prompt that names a literal `$VARNAME`, or escape it as `\$VARNAME`, or pass it through a `<<'EOF'` heredoc. Unquoted, the shell expands it before `delegate.sh` runs: an unset variable silently vanishes from the prompt and a set one sends its value, possibly a secret, to the model and, on a recipe call, into the stored input.

## Recipes

`prompts/<name>.md` holds a calibrated template for each recurring shape: the prompt skeleton, the context to gather, the example anchors and the guards, each guard traceable to a past miss. A recipe-covered task is a hard trigger, not a judgement call; do not skip the recipe because the task looks simple.

| You are about to... | Recipe |
|---|---|
| write a commit message | `commit-message` |
| write a PR description | `pr-description` |
| reply under a review comment on your own PR, after applying (or declining) the fix | `pr-review-reply` |
| post a short maintainer reply (status comment, diagnostic one-liner); you write the judgement sentence and pass it as `--var lead=...` | `maintainer-reply` |
| post a maintainer verdict on someone's change with what you verified behind it (80 words unless `--var max_words=N`) | `maintainer-review-reply` |
| write the body of a new GitHub issue from facts | `github-issue-body` |
| summarise a long issue, PR thread or CI log into a status timeline | `summarise-issue` |
| classify a list of items into a fixed set of buckets | `bulk-classify` |
| write a one-sentence summary of one document | `file-summary` |
| write one paragraph for a doc section from a fact list | `doc-section` |
| write the intro narrative of a release announcement | `release-announcement` |
| get a bounded, divergent code draft to test | `code-draft` |
| get a minimal one-file patch for a failing test | `fix-with-test` |

A shape with no recipe (a changelog entry, per-change release bullets) is still delegated as a bare `prose` call. If a shape recurs with no recipe, file a `prompt-pattern` issue; `prompts/README.md` has the recipe format.

```bash
bash scripts/delegate.sh --recipe <name> --var key=value ... ["<prompt>"] < context.txt
git diff --cached | bash scripts/delegate.sh --recipe auto --var why="<intent>"
```

A recipe declares its tier in frontmatter, so pass no tier; `--tier NAME` overrides it deliberately. The trailing prompt is optional. Piped stdin fills `{{stdin}}`, each `--var` fills its `{{key}}`, and a template with any placeholder left unfilled exits 2 naming the missing keys. `--recipe auto` reads a piped unified diff as `commit-message`, computing `diff_stat` and backfilling `recent_commits` from git, so you supply only `why`; any other input exits 2. Each recipe's "Context to gather first" section says what to collect.

Pass `--var` values literally: you already ran the `git` or `gh` command and read its output, and sandboxed shells (a Claude Code worktree session among them) refuse command substitution. Input redirection works everywhere. Give a recipe its inputs whole: full exemplars (`git log --pretty=fuller`, merged-PR bodies), never one subject line or a list of titles, and the staged diff piped to `commit-message`. A thinner input is still sent, but `delegate.sh` names it on a `weak input` stderr line and records it on the row. Pipe facts only, never instructions about the reply ("keep it under 50 words" is not a fact), and pass `ask` as the question you want asked.

Recipe calls first send a 1-token canary. If it does not answer within `DELEGATE_PREFLIGHT_TIMEOUT` seconds (default 10) the call exits 3 without sending; a model still loading from cold causes this, so rerun with `DELEGATE_PREFLIGHT_TIMEOUT=90`. After generation the recipe's deterministic checks run; a failed check earns at most one regeneration with the broken constraints appended, and what still fails shows as `checks_failed` on the meta line.

## Recording the verdict

Record a verdict after every delegation. It is the calibration signal the recipes are tuned from, and you, the agent that used or rewrote the draft, are its only judge:

```bash
bash scripts/delegate-feedback.sh --id <id> hit
bash scripts/delegate-feedback.sh --id <id> scaffold "<reason>"
bash scripts/delegate-feedback.sh --id <id> --final shipped.txt miss "<reason>"
```

`<id>` is the `id="..."` value from your own call's `delegate-meta:` line, and the reminder `delegate.sh` prints after the call carries all three commands with it filled in. Both appear only when the call wrote its metrics row; a call that wrote none has no id and nothing to record a verdict against. Copy it from there, never from a search of the metrics file: parallel sessions write that file too, and the newest row is often someone else's. Without `--id` the script attaches the verdict to the one delegation of the last 5 minutes and refuses when there are none or several.

`hit` means you shipped the draft as-is; lines that are yours to add whatever the draft said (a trailer, a `Refs` or `Closes` line, the Claude Code footer) still count as a hit. `scaffold "<reason>"` means you edited the draft and shipped it. `miss "<reason>"` means you rewrote or discarded it. A scaffold or miss without a reason exits 2. On either, add `--final <path>` (or `--final -` with the text on stdin) naming what you actually shipped: the draft is already stored, and the pair is what shows which facts the model dropped or invented. When the opt-in boundary hooks are installed (`docs/boundary-hook.md`), a credited `gh` or `git` post is stored as the final for you and the verdict adopts it when you pass no `--final`.

When you fan calls out to background shells and capture `2>&1` per call, `DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 ... 3>>nudge.log` moves the reminder off stderr; fd 3 must be redirected or the reminder is lost. `DELEGATE_LOCAL_NO_VERDICT_NUDGE=1` silences it entirely, which also means nobody records the verdict.

The boundary hook, if installed, denies an undrafted `git commit`, issue creation, comment reply or review post until a delegation for that boundary's recipe exists, and prints a command that runs as printed. If you already hold the text you will post, still delegate honestly from the facts; a verdict whose shipped text was already in the piped input is tagged ritual and left out of the hit rates, so it never counts as the draft being used. The optional `Stop` hook hands back, once per session, any delegation you left without a verdict.

## Prompt discipline

Closed prompts work; open prompts invent findings. "List the lines matching `<pattern>`", "Extract `{name, party, position}` as JSON", "Classify each TODO as P0/P1/P2", "Does this YAML match this shape? Output CLEAN or list deviations" are reliable. "Find anything interesting", "What loose ends do you see?", "Suggest improvements", "Is there something we should worry about?" produce confident concerns that do not survive verification. If the answer is valuable because the model reasons beyond the input, it is the wrong job for a local model.

- One sub-task per call. Four things to classify are four calls, not one prompt with four answers. Independent prose items of the same shape (a one-line description for each of six modules) batch into one call.
- Include a one-shot example, drawn from a different item than the real input so it cannot leak the answer, and write it as an angle-bracket skeleton rather than a fluent sentence so a leak is visible.
- For a finite output set, state priority-ordered hard rules with keyword triggers ("if the text says 'intentional' or 'by design', severity is capped at medium; this cap is non-negotiable"). An example alone does not move the model's prior; an explicit directive does. Make qualifier rules explicit too, or the model overrides "this is intentional in context Y" with its own beliefs.
- Append the anti-padding directive to every prose prompt: `Stop after the content sentences. Do not add a closing sentence that restates the point. Do not append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting") that summarises a downstream effect or implication. End on a finite verb introducing new content, or stop.` When the input opens warmly ("Hi @user", "Thanks @user"), add `If the input begins with a warm conversational opener (greeting, acknowledgement), preserve it verbatim. Do not compress greetings.`
- For a one-sentence summary, require both the subject (what was found or decided) and the mechanism, and forbid opening on a bare past-tense verb.
- When the task may be impossible to do honestly, offer a hatch: "if it cannot be completed honestly, reply with a single line beginning REFUSE: and why".

Do not ask the model to verify its own claims (it cannot read your filesystem), do not read long output as confidence, and do not put secrets in a prompt: local is safer than cloud, but the prompt still lands in shell history and, on recipe calls, in the stored input.

## Supervised code drafts

Local models are weak unsupervised agents but usable as a supervised draft generator. Within your own implementation work you may delegate one bounded code draft when the approach is genuinely forked or running the draft would teach more than reasoning about it, and always only when it is a single file or function with a named verification (a test to run or an explicit acceptance check). Use `--recipe code-draft` for a full snippet, or `--recipe fix-with-test` for a minimal patch against a failing test. The draft is disposable: apply it and run the verification, and a draft that fails it counts as a REFUSE whatever its prose says. A model can refuse in words and comply in code, so the REFUSE line is advisory and the test result is authoritative. Run model-produced code only against fixtures you control. Generic code you could write as fast yourself does not qualify. Record `miss "<reason>"` when you discarded the code, and `scaffold "<reason>"` only when you edited it into what shipped.

## Routing

`pick-model.sh <tier>` resolves a tier to the first served model in that tier's preference list. Never hardcode model names in calls; when the installed set changes, edit the preference lists in `scripts/pick-model.sh`. Providers come from `DELEGATE_BASE_URL`, an ordered list of OpenAI-compatible base URLs that defaults to MLX (`localhost:8080`), Docker Model Runner (`localhost:12434`) and Ollama (`localhost:11434`); the first reachable provider serving a preferred model wins, so MLX leads when it is running. `bash scripts/audit-models.sh` prints the routing and never pulls anything; trialling a new model is `docs/model-swap.md`. Install and launchd auto-start for MLX are in `docs/install-mlx.md`.

| Tier | Use for |
|---|---|
| `code` | Code summaries, diff explanations, renames, code drafts. |
| `prose` | Generating prose: commit messages, docs, replies, release notes. |
| `reasoning` | Extraction, classification, triage, log filtering. |
| `long-context` | Large logs, many-file scans, big diffs. |
| `premium-general` | Explicit opt-in to a larger model; resolves nothing until `config.sh` names one. |
| `embedding` | Local semantic search, through `scripts/embed.sh` and `scripts/semantic-search.sh`. |
| `vision`, `reasoning-vision` | Scaffolding only: `delegate.sh` sends text, so there is no image dispatch path. |

By default `code`, `reasoning` and `long-context` resolve the same model as `prose`, so a server that advertises every cached model never loads a second large one beside it; the tier still names the task, and `config.sh` can route it elsewhere.

The `prose` tier is for generating prose, not for inferring about it. For analytical work over a diff or log, use `reasoning` even if the input is text-heavy. When a rule applied to one item has to propagate context across the others (severity across related findings), prefer a reasoning-distilled model at enough scale over a same-size coder model; smaller is fine for independent per-item classification. Bigger is not better in general: prefer the smallest model sufficient for the task.

```bash
bash scripts/semantic-search.sh "how do I run the test suite" prompts/*.md README.md
```

## Red flags: do the work yourself

- The task needs you to read more files than the prompt can hold.
- You cannot state the task as one closed prompt.
- The user will act on the answer without reading it.
- You could not tell whether the model's answer is correct.
- The input involves secrets or credentials.
