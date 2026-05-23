# summarise-diff

## When to use

The user wants a short bullet summary of a git diff focused on user-visible changes — typically before pasting into a PR description, a release note, or a status update. The diff is small enough to fit in one prompt (≤ 8k tokens on most hosts; see SKILL.md for the practical ceiling). For multi-commit summaries that span unrelated features, do not delegate — SKILL.md flags that explicitly as a fabrication-prone task shape.

## Context to gather first

```bash
git diff <ref> --stat                    # which files changed and how much
git diff <ref>                           # full diff for the model to summarise
```

The `--stat` line lets the model anchor "9 files changed" rather than guessing scale. The full diff is the model's source of truth; without it the model summarises the stat-line shape instead of the actual change.

If the full diff is large enough to push the prompt past your host's practical ceiling, split by directory and run the recipe per-subtree instead of bundling.

## Prompt template

```
Summarise this git diff as up to {{count}} bullets focused on user-visible changes.
Use FEWER bullets if the diff has fewer distinct semantic changes — never pad to reach the count.
Each bullet is one line, present tense, starting with a verb such as Adds, Fixes, Removes, Renames, Restructures, Changes, Updates (use whichever fits; the list is illustrative, not exhaustive).
Mention the file path or feature name in each bullet so the reader can locate the change.
Each bullet must describe a DISTINCT change — do NOT restate the same change with different wording.
Do NOT invent files or features that are not in the diff.
Do NOT include test-only changes unless the test file is the only thing that changed (and call that out explicitly).
Output ONLY the bullets, no preamble.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

Example shape (do not copy literally — the input below is different):

Wrong:
- Adds `--recipe` flag to `delegate.sh` for loading prompt templates from `prompts/<name>.md`.
- Adds placeholder-validation that exits 2 when `--var` keys are missing.
- Updates `delegate.sh` to support templated recipe invocation with variable substitution.
Correct:
- Adds `--recipe` flag to `delegate.sh` for loading prompt templates from `prompts/<name>.md`.
- Adds placeholder-validation that exits 2 when `--var` keys are missing.

=== Diff stat ===
{{diff_stat}}

=== Full diff ===
{{diff}}
```

## Variables

- `{{diff_stat}}` — output of `git diff <ref> --stat`.
- `{{diff}}` — output of `git diff <ref>` (full diff). May be piped via `{{stdin}}` instead for large diffs (see Invocation below).
- `{{count}}` — number of bullets to produce; agent picks based on diff size (1 file = 1 bullet, 5+ files = 3-5 bullets). Default 3.

## Invocation

```bash
bash scripts/delegate.sh --recipe summarise-diff \
  --var diff_stat="$(git diff main --stat)" \
  --var diff="$(git diff main)" \
  --var count=3 \
  prose "Adhere to the bullet shape exactly."
```

For a large diff, the `{{stdin}}` placeholder reads the diff from the pipe:

```bash
git diff main | bash scripts/delegate.sh --recipe summarise-diff \
  --var diff_stat="$(git diff main --stat)" \
  --var diff="{{stdin}}" \
  --var count=3 \
  prose "Adhere to the bullet shape exactly."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "starting with a verb such as ..." with an illustrative list — closed verb lists were observed to be ignored (2026-05-10 dogfood: asked for the closed list and got "Changes/Adds/Updates" mixed in anyway). The looser rule keeps the verb-led shape without binding to a specific vocabulary the model rejects.
- "Use FEWER bullets if the diff has fewer distinct semantic changes — never pad to reach the count" — observed on 2026-05-10: a 1-file 2-semantic-change diff with count=3 produced two distinct bullets and a third that paraphrased the first. The "DISTINCT change" rule plus the explicit "use fewer" permission stops the padding.
- "Mention the file path or feature name" — without it bullets become vague ("improves handling") and the reader can't verify against the diff.
- "Do NOT invent files or features" — diff summaries are the highest-volume fabrication site for the prose tier; the SKILL.md "cross-PR / multi-feature commit message drafting" failure mode is the same shape (model pattern-matches on markdown and invents).
- "Do NOT include test-only changes unless..." — without this, every test file appears as its own bullet, padding the summary.
- "Output ONLY the bullets, no preamble, no trailing summary sentence" — the prose tier's anti-padding directive from SKILL.md; without it the model wraps in "Here's the summary:" and adds a closing paraphrase.

## Expected output shape

```
- Adds <feature> in `<path>` so <user-visible effect>.
- Fixes <bug> in `<path>` where <observable symptom>.
- Refactors <thing> in `<path>` (no user-visible change).
```

Verify before recording verdict: each bullet starts with a verb (ideally from the illustrative list — Adds / Fixes / Removes / Renames / Restructures / Changes / Updates), every file mentioned actually appears in the diff stat, no trailing summary sentence, bullet count is at most the requested `count` (fewer is acceptable when there are fewer distinct changes).

## Calibration notes

Initial recipe drafted 2026-05-10 from the foundational delegation pattern most heavily referenced in SKILL.md (the `git diff HEAD~5 | delegate.sh prose "Summarise..."` example in the Pattern section).

### 2026-05-10 dogfood: HIT-with-edits → recipe revision

First-pass against `qwen3.6:35b-a3b-q8_0` (prose tier) summarising the 1-file diff to `prompts/pr-description.md` with `count=3` produced three usable bullets but flagged two recipe issues:

- The closed verb list `(Adds, Fixes, Removes, Renames, Restructures)` was ignored — output used "Changes/Adds/Updates". Loosened to "such as ..." with an explicit "list is illustrative" qualifier; kept the verb-led shape constraint.
- Asking for 3 bullets on a 2-distinct-change diff produced a redundant third bullet paraphrasing the first. Added "Use FEWER bullets if the diff has fewer distinct semantic changes — never pad" plus "Each bullet must describe a DISTINCT change".

Re-validated post-revision on the same input: produced 2 bullets (not 3), both verb-led with file paths, both describing distinct changes, no preamble, no trailing summary sentence. HIT verbatim.
