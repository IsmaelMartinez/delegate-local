---
inputs:
  query: string
  files: string
  top_k: integer?
---
# semantic-search

## When to use

The agent needs to find which of a known set of files most likely contains the answer to a question, without reading every file. The classic "find the runbook that mentions X" or "which ADR covers Y" pattern — given a query and a list of N candidate files, return the top-K by cosine similarity against a local embedding model. Every file the agent skips is 1–20 KB of Sonnet input avoided, so per-call savings scale with N.

Not for: full retrieval-augmented generation (the recipe ranks files, it does not answer the question), cross-document reasoning ("which ADRs supersede each other"), or queries against files that don't yet exist on disk (no remote search). The output is a ranking — the agent then opens the top-ranked files itself to read the relevant content.

This recipe is fundamentally different from the other prompts/ recipes: it's a shell-pipeline wrapper, not a model prompt. The "template" is the `scripts/semantic-search.sh` invocation; there is no `delegate.sh --recipe` call because the wrapper assumes text-in / text-out. The recipe still lives in `prompts/` because it codifies a calibrated context-gathering pattern with anti-hallucination guards.

## Context to gather first

Decide the query phrase and the candidate file set up front:

```bash
# Pick the file set — typically a glob over docs / ADRs / runbooks.
# Smaller sets give sharper rankings; embedding cost is per-file (~50 ms
# on nomic-embed-text), so 20-100 files is the sweet spot. Past ~500
# files the agent should batch by directory or pre-filter by name first.
ls prompts/*.md docs/adr/*.md runbooks/*.md
```

The recipe takes the query as the first positional arg and the file set as the remaining args — no model prompt is generated, so no `--var` slot is needed for query-versus-files.

## Prompt template

```
bash scripts/semantic-search.sh [--top {{top_k}}] "{{query}}" {{files}}
```

Output is one line per ranked file in the form `<score> <path>`, sorted descending by score (cosine similarity, range -1 to 1 with embeddings; in practice 0.3–0.7 for related docs). The agent reads the top-K file paths itself to extract the answer; the score is advisory.

## Variables

- `{{query}}` — the search phrase. Single-quote it at the shell level if it contains `$` or backticks. Authored by the agent from the user's question or the task description.
- `{{files}}` — space-separated list of file paths (or a shell glob like `prompts/*.md` that expands to one). Authored by the agent from the relevant directory listing.
- `{{top_k}}` — optional integer. Default 5. Pass via `--top K` on the wrapper invocation; the recipe shows it inline for clarity, but the wrapper's default is reasonable for most cases.

## Invocation

```bash
bash scripts/semantic-search.sh "how do I run the test suite" prompts/*.md README.md CLAUDE.md
```

With a top-K override:

```bash
bash scripts/semantic-search.sh --top 3 "where is the metrics rollup logic" scripts/*.sh
```

Note: this recipe does NOT go through `delegate.sh --recipe semantic-search` — the recipe documents a shell pipeline, not a model prompt. The metrics row for each underlying `embed.sh` call still gets written (`source:"embed"` rather than `source:"delegate"`), so `metrics-summary.sh` will surface embedding traffic alongside delegation traffic.

## Anti-hallucination guards (each line addresses a real failure mode)

- "Output is a ranking — read the file to extract the answer." — embeddings produce a similarity score, not a passage extraction. The agent that treats `0.497 README.md` as "the answer is in README.md" without reading the file is committing the same hypothesis-treated-as-finding mistake SKILL.md's "verify every specific claim" rule warns against.
- "Score is advisory, not authoritative." — cosine similarity in the 0.3–0.5 range still means "weakly related, top of a list of N candidates", not "this file definitely answers the question". If the top score is near-tied with the second and third, the agent should open all three rather than only the highest.
- "Truncation is real and silent." — `embed.sh` head-truncates inputs longer than `DELEGATE_EMBED_MAX_CHARS` (default 6000 chars) to fit nomic-embed-text's 8192-token context. Files whose relevant content lives in the trailing 90% of the body will score poorly. Raise the env var or pre-extract the relevant section if the file shape demands it. A stderr warning surfaces the truncation event so it isn't silent in practice.
- "Skipped files emit a stderr warning, not an error." — missing or empty files in the input list are dropped from the output rather than killing the whole search. If the agent expected a file to appear in the ranking and it didn't, check stderr before assuming low similarity.

## Expected output shape

```
0.497149 README.md
0.494292 CLAUDE.md
0.474214 prompts/ci-log-triage.md
0.456229 prompts/README.md
0.454340 SKILL.md
```

Each row is `<float-score> <path>` (single space separator), sorted descending. K rows where K = `--top` value (default 5) or the number of successfully-embedded files, whichever is smaller. No header line, no trailing summary — parser-clean output for downstream `awk '{print $2}'` filtering.

Verify before acting: the top-ranked file actually contains content matching the query when opened. A high score on the wrong file is the truncation guard's most likely failure mode; if the top file looks off, re-run with `DELEGATE_EMBED_MAX_CHARS=12000` and the relevant slice in the env var.

## Calibration notes

Initial recipe drafted 2026-05-23 during the embedding-tier wire-up (ROADMAP "Capability expansion — modality tiers", P1). First dogfood: `scripts/semantic-search.sh "how do I run tests" prompts/*.md README.md CLAUDE.md SKILL.md` against `nomic-embed-text:latest` ranked README.md (0.497) and CLAUDE.md (0.494) at the top, followed by prompts/ci-log-triage.md (0.474). Both top-ranked files are exactly where the "how to run tests" guidance lives in the project, so the ranking matched the expected ground truth on the first attempt.

The recipe was designed before any baseline measurement, so this entry is the first data point rather than a calibration retrospective. Future iterations should accumulate dogfood verdicts against real "find the file that mentions X" queries — if the ranking quality drops on prose-heavy vs code-heavy file sets, the truncation guard may need a length-aware re-embedding strategy (chunk + max-pool) rather than the current head-truncation default. Out of scope for v1.

### Truncation guard origin

The default `DELEGATE_EMBED_MAX_CHARS=6000` was set empirically during the first dogfood. The HTTP 400 ("input length exceeds the context length") fires above ~7000 chars of dense markdown on `nomic-embed-text:latest`; the chars/4 token estimate over-shoots for code/log inputs because punctuation-heavy text tokenises closer to 1 token per 2 chars rather than 4. The 6000 default leaves slack for tokenizer drift; raise it for prose-heavy inputs, lower it (or chunk) for code/log inputs.
