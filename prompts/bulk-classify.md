---
inputs:
  stdin: string
  categories: string
  output_format: string
---
# bulk-classify

## When to use

You have a list of items — open issues, TODO comments, backlog tickets, log lines, changed files — and want each one assigned to exactly one category from a fixed set you supply, one structured line of output per item. The work is closed-form classification into a caller-defined taxonomy: no narrative, no cross-item reasoning, one verdict each. SKILL.md names this shape directly ("Classify each TODO as P0/P1/P2") as a closed prompt local models handle reliably.

Distinct from `ci-log-triage.md`, which triages a *single* failure log into five fixed fields. This recipe classifies *many* items into one caller-supplied category each. Pick `ci-log-triage` for "what broke in this one log"; pick this for "sort these N things into these buckets".

Not for: classification that needs the model to invent the taxonomy ("group these however makes sense" — that is `miss-theme-cluster.md`'s job, not a fixed-set assignment), or classification that depends on cross-referencing items against each other (one-item-at-a-time independent assignment is what scales down to local models; cross-reference rules need reasoning-architecture preservation — see SKILL.md's v6 finding).

## Context to gather first

```bash
# 1. The items — pipe them on stdin as {{stdin}}, one per line or per labelled
#    block. Number them if the output format references a number.
gh issue list --state open --limit 50 \
  --json number,title --jq '.[] | "#\(.number) \(.title)"' \
  > "$CLAUDE_JOB_DIR/tmp/items.txt"

# 2. The category set and the per-line output format are the caller's decision,
#    passed via --var categories=... and --var output_format=...
```

The category set is a closed list and the output format is exact: both are passed as `--var` so the same recipe serves P0/P1/P2 triage, an issue-area taxonomy, or any other fixed-set assignment without editing the recipe.

## Prompt template

```
Classify each item below into exactly one category from the CATEGORIES list. Assign exactly one category to every item. Do not invent a category outside the list; if an item fits none well, use the closest listed category (or the explicit catch-all category if the list names one).

Rules:
- Output exactly one line per input item, in the same order as the input. Do not skip an item, do not merge two items into one line, do not add extra lines.
- The category on each line MUST be one of the CATEGORIES verbatim. Never invent a synonym, abbreviation, or new category.
- Format each line exactly as: {{output_format}}
- Where the format requires verbatim item text, reproduce it exactly as given; do not paraphrase, truncate (unless the format says to), or re-order words.
- Output ONLY the per-item lines. No header row, no preamble, no commentary, no blank lines between items, no trailing summary. Stop after the last item's line.

=== CATEGORIES (the closed set — every item maps to exactly one of these) ===
{{categories}}

=== ITEMS (one per line or per labelled block, in order) ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the items to classify, piped in, one per line or per labelled block, in the order the output should follow. No `--var` slot needed.
- `{{categories}}` — the closed category set, as a comma-separated or newline list. Every item is assigned exactly one of these verbatim; the model never invents one outside the set. Name an explicit catch-all (e.g. `other`) if you want unmatched items to land somewhere predictable.
- `{{output_format}}` — the exact per-line output shape, e.g. `NUMBER | CATEGORY | one-sentence summary` or `<P0|P1|P2>: <verbatim todo>`. Be specific about delimiters and whether the original item text is reproduced verbatim.

## Invocation

```bash
bash scripts/delegate.sh --recipe bulk-classify \
  --var categories="display-session-media, auth-network-edge, tray-notifications, packaging, configuration-cli, enhancement, other" \
  --var output_format='NUMBER | CATEGORY | one-sentence summary' \
  reasoning "One line per item, in order. Category must be one of the listed set verbatim. No headers, no commentary." \
  < "$CLAUDE_JOB_DIR/tmp/items.txt"
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit   # or: miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "The category ... MUST be one of the CATEGORIES verbatim. Never invent a synonym" — the highest-volume failure mode on closed-set classification: the model emits a plausible near-synonym (`config` for `configuration-cli`, `urgent` for `P0`) that breaks any downstream parser. The verbatim-from-the-list discipline is the same closed-list rule `ci-log-triage.md` applies to its FAILURE_TYPE enum.
- "one line per input item, in the same order ... do not skip an item, do not merge two" — on a long list the prose tier drops or coalesces items, especially near-duplicate ones. The one-line-per-item-in-order rule keeps the output count equal to the input count so a mismatch is immediately visible.
- "if an item fits none well, use the closest listed category (or the explicit catch-all ...)" — the closed-list escape hatch. Without a defined fallback the model invents a new bucket for the awkward item; naming `other` (when the caller lists it) gives the awkward items a predictable home, per the REFUSE/escape-hatch pattern in SKILL.md.
- "Output ONLY the per-item lines. No header row, no preamble, no trailing summary" — reasoning-tier models otherwise wrap the output in a `## Classification` header or close with a count summary, which the parser then has to strip.
- The `reasoning` tier (not `prose`) is intentional, the same argument `ci-log-triage.md` makes: classification is filtering and assignment, not prose generation. Per SKILL.md's 2026-05-03 v7 finding, independent per-item classification with priority-ordered keyword rules scales down well to local reasoning models; spell the category boundaries out as hard rules in `--var categories` if the default assignment drifts.

## Expected output shape

```
#412 | display-session-media | Screen share shows a black window on Wayland.
#418 | auth-network-edge | SSO login loops when the system clock is skewed.
#421 | packaging | AppImage fails to launch on Ubuntu 24.04 due to a missing libfuse2.
```

Verify before recording verdict: exactly one output line per input item, in input order; every category is one of the supplied set verbatim (grep-check against `--var categories` if unsure); each line matches the `output_format` exactly; verbatim item text (where the format requires it) is unparaphrased; no header, preamble, or trailing summary.

## Calibration notes

Graduated 2026-06-16 from observed recurring bare-delegation usage rather than from a recorded HIT. A 2026-06-15 analysis of the session-transcript corpus found fixed-taxonomy classification of a list to be a recurring task shape with no recipe — the closest, `ci-log-triage.md`, handles a single log into five fields, not N items into one caller-supplied category each. The shape fell back to the bare `reasoning`/`prose` tier each time, with the closed-list and output-format directives re-specified by hand.

The prompt skeleton is lifted from the actual bare prompts used, which had converged on the same guards independently: "Classify each issue below into exactly one category from this list: [taxonomy]. Output format: one line per issue as 'NUMBER | CATEGORY | one-sentence summary'. No headers, no commentary. Stop after the last issue line." and the P0/P1/P2 TODO variant "Output exactly one line per input: '<P0|P1|P2>: <verbatim todo>'. No commentary." The verbatim-category and one-line-per-item rules are what this recipe makes permanent.

### 2026-06-16 — first dogfood (HIT)

First dogfood against `deepseek-r1:32b` (reasoning tier, Ollama): four `#NNN`-prefixed teams-for-linux issues into a seven-category set. Output was a clean HIT on mechanics — exactly one line per item in input order, every category drawn verbatim from the supplied set, the `NUMBER | CATEGORY | one-sentence summary` format exact, no header, preamble, or trailing summary. Recorded HIT via `delegate-feedback.sh --source agent`. The one arguable call was `#430 "Add a setting to disable the tray icon"` landing in `configuration-cli` rather than `enhancement` — a defensible read (a setting is configuration), and exactly the category-boundary ambiguity this recipe's guards anticipate rather than a format failure. Per SKILL.md's v5/v7 calibration history, the established fix for boundary drift is to spell the boundary out as a priority-ordered hard rule inside `--var categories` and add a one-shot example, not to loosen the verbatim-category constraint. No recipe change was needed from this dogfood.
