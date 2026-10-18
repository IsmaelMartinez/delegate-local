---
name: delegate-local
description: Use this skill to read a large text input on this machine instead of in your own context, by piping it in chunks to a local model (MLX, Ollama or Docker Model Runner) via `delegate.sh` for a short, anchored answer you spot-check. MUST use when the input is too large to be worth reading in full (a long log, a big diff, a long issue or PR thread, a document, dozens of files or a long list of items, roughly 20k characters or more) and the answer you need is a summary, the matching lines, extracted fields or a label per item. MUST also use when content must stay on this device or offline, or when the user explicitly asks to delegate or names a local model. Do NOT use for text you will publish or post (commit messages, PR descriptions, issue bodies, review or maintainer replies, release notes, documentation prose): write those yourself. Do NOT use for small inputs you have already read, code review, debugging, architecture, implementation, or open-ended prompts that ask the model to find things not in the input.
---

# Delegate Local

Read a large input on this machine so it never enters your context. You decide what to ask; a local model reads the input in chunks and returns a short answer with anchors (quoted lines, line numbers, item ids) that you verify with `grep` instead of reading the input. Since ADR 0035 this is the skill's only job: drafting text you will publish costs more of your output tokens than it saves, so write that yourself.

Paths below are relative to the skill directory (`~/.claude/skills/delegate-local/` on a Claude Code install).

## When to delegate

Fits, when the input is large and you have not read it:
- Summarise a long log, issue or PR thread, or document into what happened, what is blocking and what is next.
- List only the lines of a log or diff that match a condition you state.
- Extract named fields from a long text as JSON.
- Classify each of many items (tickets, TODOs, files, log lines) into a fixed set of categories you supply.
- Give a one-line summary of each file in a directory.

Do NOT delegate:
- Anything you will publish or post: commit messages, PR descriptions, issue bodies, review or maintainer replies, release notes, documentation.
- Small inputs, or inputs you have already read: piping them costs a brief and a read-back and saves nothing.
- Multi-step reasoning, planning, tool-calling, code correctness, security or architectural judgements.
- Anything whose output directly triggers a destructive or shared-state action without your review.

When the content may leave the machine and the user has not asked for a local model, a subagent on a small cloud model is an equally good way to keep a large input out of your context. The local path is the one to take when the content must stay on the device.

## Pattern: filter, chunk, anchor, spot-check

1. Filter first. `grep`, `jq`, `awk` or `git log --grep` answer most questions about a large input for free and exactly; delegate only the part that needs reading.
2. Chunk. Local models lose track of long inputs well before their advertised context, so send at most about 30k characters (about 8k tokens) per call and ask the same closed question of each chunk.
3. Anchor. Ask for line numbers, quoted lines or item ids with every claim, and a REFUSE line when the chunk does not contain the answer.
4. Spot-check and combine. Verify a sample of anchors with `grep -n` against the input, then combine the chunk answers yourself. The output is a pointer to where to look, not a finding.

```bash
grep -nE 'ERROR|FAIL|panic' build.log | bash scripts/delegate.sh reasoning \
  "Group these log lines by root cause. One line per cause: the cause, then the line numbers it covers."
d="${TMPDIR:-/tmp}/delegate-chunks.$$"; mkdir -p "$d"
grep -n '' big.log | split -l 400 -a 4 - "$d/chunk."
for c in "$d"/chunk.*; do
  bash scripts/delegate.sh reasoning "Each line starts with its line number and a colon. List each line that reports a timeout as <number>: <quoted line>. If none, reply REFUSE: none." < "$c"
done
rm -r "$d"
```

`grep -n` numbers the lines before the split, so every anchor is a line number in the original file; a fresh directory per run keeps leftover chunks out, and a four-letter suffix leaves room for any number of chunks.

`delegate.sh <tier> "<prompt>"` takes the input on stdin, resolves the tier with `pick-model.sh`, and posts to the winning provider's `{base}/chat/completions` with `temperature:0` and thinking off. The answer is plain text on stdout. After each successful call a `delegate-meta:` line on stderr names the `model`, `tier`, `backend`, `tokens_local` (characters in and out divided by 4, which is what stayed local, not a saving) and `duration_ms`; in your reply, say the input was read locally and name the model, e.g. "Read locally by <model> (reasoning tier), 41k characters in 12 s." Each call appends one row to `~/.local/share/delegate-local/metrics.jsonl`; `DELEGATE_LOCAL_NO_METRICS=1` opts out. The first call to a model that is not loaded can take tens of seconds; a call that runs well past a minute with no output should be killed and split.

Single-quote any prompt that names a literal `$VARNAME`, or pass it through a `<<'EOF'` heredoc, so the shell does not expand it. Never put secrets in a prompt: it lands in shell history and, on recipe calls, in the stored input.

## Recipes

Three recipes in `prompts/` fit the shape. Each declares its tier, so pass no tier.

| You need | Recipe |
|---|---|
| a status timeline of a long issue, PR thread or CI log | `summarise-issue` (`--var kind=... --var N_FACTS=...`) |
| a label per item from a fixed set | `bulk-classify` (`--var categories=... --var output_format=...`) |
| a one-sentence summary of one document, one call per file | `file-summary` |

```bash
gh issue view 142 --comments | bash scripts/delegate.sh --recipe summarise-issue --var kind=issue --var N_FACTS=5
```

Piped stdin fills `{{stdin}}` and each `--var` fills its `{{key}}`; a missing key exits 2. Recipe calls first send a 1-token canary and exit 3 when it does not answer within `DELEGATE_PREFLIGHT_TIMEOUT` seconds (default 10), which a cold model causes: rerun with `DELEGATE_PREFLIGHT_TIMEOUT=90`. For a batch over many files, run the calls one after another, not in parallel.

## Prompt discipline

Closed prompts work; open prompts invent findings. "List the lines matching", "Extract these fields as JSON", "Classify each item as P0, P1 or P2" are reliable. "Find anything interesting" or "suggest improvements" produce confident claims that do not survive a check. One question per call. Give a one-shot example as an angle-bracket skeleton (`<line number>: <quoted line>`), drawn from a different item than the input, so a leak is visible. For a fixed output set, state priority-ordered rules with keyword triggers rather than relying on the example.

## Routing

`pick-model.sh <tier>` resolves a tier to the first served model in that tier's preference list; never hardcode model names in calls. Providers come from `DELEGATE_BASE_URL`, defaulting to MLX (`localhost:8080`), Docker Model Runner (`localhost:12434`) and Ollama (`localhost:11434`), first reachable wins. Use `reasoning` for filtering, extraction and classification, `long-context` for the largest chunks, and `prose` for summaries; by default they resolve the same model. If no provider is reachable the call fails: do the work another way and say why.

## Red flags: do it another way

- The answer depends on combining facts from across the whole input in one step.
- You cannot state the question as one closed prompt per chunk.
- You will act on the answer without spot-checking an anchor.
- The input holds secrets or credentials.
