---
inputs:
  file_path: string
  stdin: string
---
# bulk-file-summary

## When to use

The agent is orienting in an unfamiliar repo (or unfamiliar area of an existing repo) and needs one-line descriptions for N files (5-50 typical, 1-20 KB each) before deciding which ones to read in full. Pick this recipe over `file-summary.md` whenever the task is batch-shaped — the loop variant lets each call stay independently small (one file per delegation) and the per-file directives explicitly forbid the model from inventing cross-file relationships between batch siblings.

Not for: single-file summaries (use `file-summary.md` directly; this recipe's batch-awareness directives are wasted on N=1), summaries that require cross-document reasoning ("which of these files supersedes the others"), or one-line digests for a heterogeneous mix of file types where one prompt shape cannot cover both (split by type and run the recipe per subset). Output is one short line per file; the caller is expected to prepend the file path itself so the output stays grep-clean.

## Context to gather first

```bash
# Pick the file set — typically a glob over a single directory or file type.
# Smaller sets give the model less opportunity to conflate siblings; 5-50
# files is the sweet spot for the batch shape.
ls prompts/*.md
ls scripts/*.sh
ls src/auth/*.ts
```

Optional pre-filter for very large N (> 20 files) via the embedding tier — the agent can rank files against a query and bulk-summarise only the top-K, instead of summarising every file in the directory:

```bash
# Rank 50 candidate files against the question first, then summarise only
# the top 10. Saves ~80% of the per-file delegations on the long tail.
bash scripts/semantic-search.sh --top 10 "where is the auth middleware" src/**/*.ts \
  | awk '{print $2}' \
  | while read -r f; do
      printf '%s — ' "$f"
      cat "$f" | bash scripts/delegate.sh --recipe bulk-file-summary \
        --var file_path="$f" prose "One line only."
    done
```

The recipe takes the file body via `{{stdin}}` and the file path via `--var file_path=...` so the model knows which file it is summarising (the path is part of the prompt frame, not just an output decoration). Loop the invocation over a glob for the batch.

## Prompt template

```
Summarise the SINGLE file below in ONE SHORT SENTENCE (<=20 words) describing what THIS file's primary purpose is. Do not invent imports, callers, or relationships to other files in the same batch.

Rules:
- Output exactly one line. No markdown, no bullets, no preamble, no quotes, no leading dash, no file path prefix (the caller prepends the path).
- Describe what THIS file does on its own terms — its primary purpose, the main type it exports, or the principal behaviour it implements. The agent is reading N files in a batch; do NOT speculate about how this file relates to its batch siblings ("works with X", "consumed by Y") unless the relationship is named verbatim inside this file itself.
- Sentence must include both the SUBJECT (what the file is or does) and the SHAPE (function/class/script/recipe/config — whichever fits). Do NOT begin with a bare past-tense verb that omits the subject.
- Do NOT include the file path or filename in the output — these go in the caller's loop prefix.
- Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

Example shape (do not copy literally — the input below is different):

Wrong: Works alongside the other auth modules to handle session validation across the batch.
Correct: Exports the `refreshSession` middleware that validates a JWT against the auth-cache and rotates the cookie before forwarding the request.

=== File path ===
{{file_path}}

=== File body ===
{{stdin}}
```

## Variables

- `{{file_path}}` — the path of the file being summarised, e.g. `src/auth/middleware.ts`. Names the file so the model knows what it is summarising; the caller is responsible for prepending the path to the model output if the per-line shape is `<path> — <summary>`.
- `{{stdin}}` — the file body, piped in. No `--var` slot needed.

## Invocation

Single-file form (one delegation, one summary):

```bash
cat src/auth/middleware.ts | bash scripts/delegate.sh --recipe bulk-file-summary \
  --var file_path=src/auth/middleware.ts \
  prose "One line only. Describe this file's primary purpose."
```

Batch over a glob (recommended — each call stays independently small, fits the prose-tier ceiling per issue #110):

```bash
for f in prompts/*.md; do
  printf '%s — ' "$(basename "$f")"
  cat "$f" | bash scripts/delegate.sh --recipe bulk-file-summary \
    --var file_path="$f" \
    prose "One line only. Describe this file's primary purpose."
done
```

After each call, record the verdict so the recipe library can self-correct:

```bash
bash scripts/delegate-feedback.sh hit
# or
bash scripts/delegate-feedback.sh miss "<reason>"
```

For batch verdicts where every output was usable, run one `hit` per call rather than one for the whole batch — `delegate-feedback.sh` attaches to the most-recent metrics row by default and a batch-level verdict would only land on the final call.

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Describe what THIS file does on its own terms ... do NOT speculate about how this file relates to its batch siblings" — the batch shape is the recipe's reason for existing. The model has access only to one file per delegation, so any sentence claiming `<this file> works with <sibling>` or `<this file> is consumed by <sibling>` is necessarily speculative. Inherited from the same family as `summarise-diff.md`'s "Do NOT invent files or features" guard but pointed at the cross-file-relationship failure mode specifically. This is the load-bearing guard that separates `bulk-file-summary` from `file-summary` — the batch context is the new failure mode.
- "Sentence must include both the SUBJECT and the SHAPE" with the "Do NOT begin with a bare past-tense verb" follow-up — inherited from `file-summary.md`'s 2026-05-11 calibration finding (issue #95) where the prose tier latched onto example opener verbs (`Confirmed`, `Found`, `Showed`) and emitted `<verb> because <mechanism>` participial fragments dropping the subject. Same failure shape applies here — without the SUBJECT-required guard the model defaults to `Implements X by Y` constructions that read as participial fragments rather than complete sentences. Carried forward because the parent calibration is the strongest evidence in the recipe library for this guard.
- "Output exactly one line. No markdown, no bullets, no preamble, no quotes, no leading dash, no file path prefix" — without it the model wraps in ``` blocks, prefixes with `Summary:`, emits a leading dash, or repeats the file path in the output. The path prefix exclusion is specific to this recipe — `file-summary.md` doesn't ship file paths via `--var`, so the prefix-leak failure mode is new here.
- "(<=20 words)" — without an explicit word budget the model expands to ~35-word complete sentences. Slightly tighter than `file-summary.md`'s 25-word budget because batch output is meant to scan vertically in a directory listing rather than read linearly in an index — 20 words wraps cleanly at 100 cols with the prepended path.
- Canonical anti-padding directive (the long enumeration) — copied byte-for-byte from `file-summary.md` and `summarise-diff.md` after the 2026-05-21 / 2026-05-23 sweep aligned every recipe's enumerated forbidden phrases with `experiments/score-t4.sh`'s `PADDING_REGEXES`. The scorer is the empirical gate, so the prompt's enumeration must at minimum name every shape the scorer rejects, otherwise model misses on scorer-only verbs are not actionable from the model's point of view. The Phase 13 entry (#195) in ROADMAP documents the alignment.

## Expected output shape

```
Resolves a tier name to a model identifier by scanning the installed-model registry against a substring preference list.
```

```
Wraps `embed.sh` in a cosine-similarity ranker that prints `<score> <path>` lines sorted descending against a query embedding.
```

Verify before recording verdict: one line only, includes a subject noun phrase plus a shape noun (function, class, script, recipe, config), no leading verb-fragment, no file path or filename in the output, no trailing restatement, no cross-file-relationship claim that the file body does not state verbatim, ≤20 words.

## Calibration notes

Initial recipe drafted 2026-05-24 to unblock the ROADMAP P3 "deferred-until-trigger" recipe entry under "Other open priorities / Recipe library expansion" (lines ~109-117 of ROADMAP.md). The trigger condition — "any future session where the agent reads ≥ 5 files just to orient before editing" — fired during the embedding-tier wire-up session because the user explicitly asked for the recipes the embedding tier (#204) opens up, and `bulk-file-summary` is the closest sibling to `semantic-search` in the input-digestion family.

### Shape decision: per-file loop (Shape B) over single-call digest (Shape A)

Two shapes were considered. Shape A concatenates all N files into one big input with `=== FILE: path ===` separators and asks the model for one structured line per file in a single delegation. Shape B (this recipe) makes the recipe itself a per-file template and shows a bash loop in `## Invocation` that calls the recipe once per file.

Shape B was chosen for empirical reasons. Issue #110's measurement against `qwen3.6:35b-a3b-q8_0` on the reference host shows the 35B prose-tier model stalling at ~3-4 KB of recipe-shaped input — a single delegation summarising 20 files at 1.5 KB each would push the input to ~30 KB and stall reliably. The per-file loop variant keeps each call independently small (~2-3 KB of recipe template plus one file body), matching exactly the input ceiling `file-summary.md`'s 24-call batch already cleared in issue #95. The N delegations are sequential and slower wall-clock than a hypothetical one-call digest, but the existing batch evidence is that the per-call latency on a 1.5 KB body is ~3-10 seconds and a 20-file batch completes in ~2-3 minutes — comfortably inside the working session.

A compact-mode Shape A is documented here as a future option for cases where N ≤ 10 and total input is < 5 KB, but not implemented in this recipe. Adding it would mean shipping a second prompt template inside the same file; the existing single-prompt-per-recipe convention keeps the structural-validity gate simple and matches every other recipe in the library.

### Cross-file-relationship guard origin

The new guard ("do NOT speculate about how this file relates to its batch siblings") was not directly observed in a session before this recipe shipped — it is a predicted failure mode by analogy from `summarise-diff.md`'s "Do NOT invent files" guard and from the general pattern that batched calls invite the model to imagine context that isn't in any single call. The next dogfood cycle on this recipe will record whether the guard binds or whether the model needs a Wrong/Correct one-shot example of the cross-file-relationship failure shape to anchor the directive concretely. Treating the recipe as "ship-then-measure" rather than "measure-then-ship" on this guard because the parent recipes' evidence base for adjacent guards is strong enough to justify the structural starting point.

### Dogfood 2026-05-24

First batch dogfood against `qwen3.6:35b-a3b-q8_0` (prose tier, Ollama backend) over 7 sibling recipes — `em-dash-removal.md`, `release-note.md`, `jira-ticket-description.md`, `doc-section.md`, `presentation-slide-prose.md`, `pr-review-reply.md`, `summarise-issue.md`, `roadmap-entry.md`. Per-call wall-clock 3.8-22.6 seconds (median ~5 s), per-call `tokens_local` 4.3-14.6 KB. Each delegation produced one short sentence describing the file's primary purpose with the SUBJECT + SHAPE structure the recipe directs (e.g. `Defines a recipe for ...`, `Defines the release-note recipe that ...`). All seven outputs HIT verbatim on first attempt — no padding tails, no preamble, no markdown fences, no cross-file-relationship claims, no file path prefixes. Per-call verdicts recorded via `delegate-feedback.sh hit` against each delegate row's metrics ts.

The cross-file-relationship guard binding cleanly on the first dogfood is the load-bearing signal: the model encountered seven sibling files from the same `prompts/` directory in the same batch and described each one strictly on its own terms (`Defines the X recipe that ...`) without claiming a relationship to any of the others. The 7/7 first-pass HIT rate matches the `file-summary.md` parent recipe's 23/24 first-batch rate against the same model class — strong enough to ship without a contrastive Wrong/Correct anchor for the cross-file guard, with the open question being whether a more heterogeneous batch (mixed file types, mixed directories) surfaces a different failure mode that would justify promoting the bare-negation to a v5/v7 directive-rule.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is generating one sentence of prose per file body; it is not classification, not extraction, not analysis. Anyone reaching for `reasoning` or `long-context` here is over-spending — the per-file shape fits prose-tier cleanly when the inputs stay below the recipe-stall ceiling, and that's exactly what Shape B was chosen to guarantee.
