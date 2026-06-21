---
inputs:
  commit_subjects: string
  why: string?
checks:
  subject_max: 72
  no_padding_tail: true
---
# pr-title

## When to use

The user has a branch with one or more commits and wants a single GitHub PR title — conventional-commit shape, ≤72 characters — to paste into `gh pr create --title "..."`. This is the title only; `pr-description.md` drafts the body. Split out because a one-line title is a much smaller, more reliable delegation than a full body (the body recipe is flaky on 35B+ prose hosts per its `flaky_on_models` gate; the title is not), and because the agent routinely needs the title independently of the body. The recurring shape in the session corpus is "draft PR title (conventional-commit, ≤72 chars)".

## Context to gather first

```bash
# The branch's commit subjects, oldest first, are the load-bearing context:
# the model synthesises ONE title across them rather than copying the first.
git log <base-branch>..HEAD --reverse --pretty=format:'%s'
```

One line per commit subject, in order. The title summarises the whole branch, so the model needs every subject, not just the latest. If the branch is a single commit, the title will closely track that commit's subject — that is correct, not a failure.

## Prompt template

```
Write exactly ONE GitHub pull-request title that summarises the WHOLE branch below.

Rules:
- Conventional-commit form: `type: summary` or `type(scope): summary`. Choose the single type that best covers the branch as a whole ({{flavor_commit_types}}).
- Maximum 72 characters total. Shorter is better.
- Imperative mood, lower-case after the colon, no trailing period.
- Synthesise across ALL the commit subjects into one line. Do NOT just copy the first or last subject; describe what the branch does as a unit.
- Do NOT append a PR number, `(#NN)`, an issue reference, or the branch name.
- Output ONLY the single title line — no body, no surrounding quotes, no commentary, no markdown fence.

Example:
  Commit subjects:
    add retry to the upload client
    handle 429 from the upload client
    test: cover upload retry backoff
  -> fix(upload): retry uploads on 429 with backoff

=== Commit subjects (the branch, oldest first) ===
{{commit_subjects}}

=== Intent (optional — why this branch exists) ===
{{why}}
```

## Variables

- `{{commit_subjects}}` — the branch's commit subject lines, one per line, oldest first (the shape anchor for the whole-branch summary). Piped in or passed via `--var`; no body, just subjects.
- `{{why}}` — optional one-line statement of the branch's intent, when the commit subjects alone do not make the "why" obvious. Omit it and the section stays empty; the title then rests on the subjects alone.
- `{{flavor_commit_types}}` — allowed conventional-commit type vocabulary for the title prefix. Injected from the flavor profile, not passed via `--var`: shipped default `feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert` (the @commitlint/config-conventional standard enum), overridable per-user. Shared with `commit-message.md` so the title and the commit messages draw on the same type set.

## Invocation

```bash
# Pass the subjects via --var only (the template uses {{commit_subjects}}, not
# {{stdin}}, so do NOT also pipe — that would duplicate them and run git twice).
subjects="$(git log main..HEAD --reverse --pretty=format:'%s')"
bash scripts/delegate.sh --recipe pr-title \
  --var commit_subjects="$subjects" \
  --var why="recover capability-check failures on a stronger model" \
  code "One conventional-commit title, <=72 chars, no (#NN). Output only the title line."
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit   # or: miss "<reason>"
```

The `subject_max: 72` check is a capability check: it deterministically flags a rambling over-72-char title after generation so the caller can shorten it or re-run on a stronger tier.

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Maximum 72 characters total" — the highest-volume title failure: the model writes a sentence-length title. The `subject_max: 72` deterministic check flags it after the fact; the prompt rule reduces how often it happens.
- "Synthesise across ALL the commit subjects ... do NOT just copy the first or last" — on a multi-commit branch the weak-model default is to echo one subject verbatim, which under-describes the branch. The synthesise directive plus the multi-line worked example pushes toward a unifying summary.
- "Do NOT append a PR number, `(#NN)`, an issue reference, or the branch name" — the same `(#NN)`-suffix miss the commit-message recipe guards against, which breaks the clean conventional-commit shape and double-references the number GitHub already shows.
- "Output ONLY the single title line — no body ... no markdown fence" — small models otherwise wrap the title in a ` ```text ` fence or add a one-line explanation, which the caller then has to strip before `gh pr create --title`.
- The single-type rule ("choose the single type that best covers the branch as a whole") — a branch that mixes a fix and a test should not produce `fix, test:`; conventional commit allows exactly one type. Naming the closed type set in the prompt (via the shared `{{flavor_commit_types}}` vocabulary, the same source `commit-message.md` uses) keeps the model from inventing a compound or non-standard type.

## Expected output shape

```
feat: restore semantic-search and embed scripts with tests
```

Verify before recording the verdict: exactly one line; `type:` or `type(scope):` prefix using one of the listed types; ≤72 characters; no trailing period; no `(#NN)` / issue / branch suffix; the title describes the whole branch rather than a single commit.

## Calibration notes

Graduated 2026-06-18 from the session-transcript corpus rather than a single recorded HIT. A mining pass over the session history found "draft PR title (conventional-commit, ≤72 chars)" recurring verbatim across multiple projects, folded into `pr-description.md` each time even when only the title was wanted. Splitting it out gives the agent a small, reliable title-only delegation that is not subject to the body recipe's 35B/80B `flaky_on_models` stall, and a `subject_max: 72` capability check that deterministically flags an over-length title. The prompt skeleton reuses the proven guards from `commit-message.md` (no `(#NN)` suffix, single conventional-commit type via the shared `{{flavor_commit_types}}` vocabulary, output-only discipline) narrowed to a single line, plus the whole-branch-synthesis directive specific to titles spanning multiple commits.

First dogfood (2026-06-18, 3-commit branch): the 0.6B produced a clean 55-char title — a HIT — while the Coder-30B on the same input produced a faithful but 73-char title that the `subject_max: 72` check correctly flagged. The check does its job: the directive's "Shorter is better" line plus the deterministic check are the two levers, not a longer prompt.
