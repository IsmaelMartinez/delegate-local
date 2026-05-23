# file-summary

## When to use

The agent needs a one-sentence summary of a single document — an ADR, an analysis note, a design doc, a meeting note — for a link-index, a digest, or a status update. Output is one short line describing the decision/outcome (for ADRs) or headline finding (for analyses) plus the reason. Scales to batched per-file invocations across a directory; the 2026-05-11 batch in issue #95 ran 24 such calls back-to-back at ~3–10 s each on `qwen3.6:35b-a3b-q8_0` with no hangs.

Not for: multi-file summaries (split per file and stitch yourself), summaries that need cross-document reasoning ("which of these ADRs supersedes the others"), or any summary where the link text already carries the title/date/session number — the recipe deliberately strips those because they belong in the link.

## Context to gather first

```bash
# The file body to summarise — pipe it on stdin as {{stdin}}:
cat path/to/adr-0007-something.md
# Or for a batch loop:
for f in docs/adr/*.md; do
  cat "$f" | bash scripts/delegate.sh --recipe file-summary prose "..."
done
```

The recipe takes the file body via `{{stdin}}` so a single recipe invocation summarises one file. Loop the invocation over a glob for a batch.

## Prompt template

```
Read the document below and output ONE SHORT SENTENCE (<=25 words) describing the decision/outcome (for ADRs) or headline finding (for analyses) and the reason.

Rules:
- Output exactly one line. No markdown, no bullets, no preamble, no quotes, no leading dash.
- Sentence must include both the SUBJECT (what was decided/found) and the MECHANISM (because/by which thing).
- Do NOT begin with a bare past-tense verb that omits the subject — always state WHAT was confirmed or found.
- Do NOT include the title, session number, or date — these go in the link text.
- Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

Example shape (do not copy literally — the input below is different):

Wrong: Confirmed because slope conditioning reveals heterogeneity that the 2-axis grid averages out across slope buckets.
Correct: The 3-axis grid surfaces one new regime cell missed by the 2-axis grid because slope conditioning reveals heterogeneity averaged out in the broader grid.

=== Document ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the document body, piped in. No `--var` slot needed.

## Invocation

```bash
cat docs/adr/0007-something.md | bash scripts/delegate.sh --recipe file-summary \
  prose "One sentence only. Include the subject and the mechanism."
```

Batch over a directory:

```bash
for f in docs/adr/*.md; do
  printf '%s — ' "$(basename "$f")"
  cat "$f" | bash scripts/delegate.sh --recipe file-summary \
    prose "One sentence only. Include the subject and the mechanism."
done
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Sentence must include both the SUBJECT and the MECHANISM" with the explicit "Do NOT begin with a bare past-tense verb" follow-up — the 2026-05-11 batch observed the model latching onto example opener verbs (`Confirmed`, `Found`, `Showed`, `Identified`, `Rejected`) and emitting `<verb> because <mechanism>` participial fragments that dropped the subject. Same family as SKILL.md's anti-padding directive — verb-led-fragment is the opening counterpart.
- "Output exactly one line. No markdown, no bullets, no preamble, no quotes, no leading dash" — without it the model wraps in ``` blocks, prefixes with `Summary:`, or emits a leading dash for the summary line.
- "Do NOT include the title, session number, or date" — the document body usually has them in the heading; including them in the summary doubles up with the link text in the consuming index.
- "Do NOT add a trailing clause that restates the point. Stop immediately after the mechanism." — the prose-tier padding rule from SKILL.md, applied to a one-sentence target where padding is most expensive (the trailing clause becomes a quarter of the sentence).
- "(<=25 words)" — without an explicit word budget the model expands to ~40-word "complete" sentences; 25 is the longest a one-line summary stays readable in a markdown index without wrapping at 80 cols.

## Expected output shape

```
The 3-axis grid surfaces one new regime cell missed by the 2-axis grid because slope conditioning reveals heterogeneity averaged out in the broader grid.
```

```
CloudWAN was accepted over Transit Gateway because the global routing model handles cross-region intent at the policy layer instead of in per-attachment route tables.
```

Verify before recording verdict: one line only, includes both a subject noun phrase and a `because`/`by` mechanism clause, no leading verb-fragment opener, no title or date, no trailing restatement, ≤25 words.

## Calibration notes

Initial recipe drafted 2026-05-11 from the 24-call batch summarisation reported in issue #95 — ADR and analysis files in a sibling repo summarised against `qwen3.6:35b-a3b-q8_0` via `scripts/delegate.sh prose`. The first-batch hit rate was 23 of 24; the single MISS dropped the subject and emitted `Confirmed because slope conditioning reveals heterogeneity that the 2-axis grid averages out across slope buckets.` — exactly the verb-led-fragment shape the subject-required guard now blocks. The re-prompt with the explicit subject directive produced `The 3-axis grid surfaces one new regime cell missed by the 2-axis grid because slope conditioning reveals heterogeneity averaged out in the broader grid.` on the same input.

The 95%+ first-pass rate on a 24-call batch is the empirical anchor for treating this recipe as ready-to-ship rather than "starting point, calibrate later". The remaining ~4% miss rate motivates the subject-required guard rather than a spot-check workflow — the recipe is meant for batch use across many files where per-file review defeats the point.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is generating one sentence of prose from a document body; it is not classification, not extraction, not analysis. Anyone reaching for `reasoning` here is over-spending — the 2026-05-11 batch confirmed prose-tier is sufficient when the subject-required guard is in the prompt.
