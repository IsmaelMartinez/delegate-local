# What "tokens avoided" actually avoided: design

**Date:** 2026-08-19
**Issue:** #412

An adversarial review of the first draft found six blockers. The central one
inverted the approach: the first draft redefined the headline, which silently
repealed a deliberate cross-source contract and broke two tests. This draft
leaves the headline alone and adds the decomposition beneath it.

## The bug

`estimated_tokens_avoided` is `(prompt_chars + context_chars + output_chars) / 4`
written on **every** delegate row, including calls that failed and drafts the
agent then rewrote. `metrics-summary.sh` prints one unqualified total, so the
number reads as a saving when roughly half of it is not.

What the tool prints after this change (a live snapshot; the file grows, so the
figures move while the two reconciliation identities below do not):

```
Tokens avoided (≈):  3125030
  excluded: experiment rows       tokens≈75293  n=48
  excluded: failed delegations    tokens≈235514  n=121
  successful delegations          tokens≈2814223  n=1423
    shipped as-is     tokens≈1498108  53.2%  n=692
    rewritten         tokens≈547781  19.5%  n=227
    used as scaffold  tokens≈37613  1.3%  n=21
    no verdict        tokens≈730721  26.0%  n=483
```

Two identities hold by construction and are asserted: the three sub-lines sum to
the headline, and the four buckets sum to the successful subtotal.

The ~19% rewritten is work the frontier model did anyway, so those tokens were
spent twice rather than avoided.

The first draft's table opened with 3,049,737 and called it "the headline". It
is not: the headline's `call` filter is `src != "feedback" and src !=
"opportunity"`, so it includes experiment rows. 3,049,737 is the delegate-only
subtotal, and the real figure the tool prints is 3,125,030.

## Decision

### The headline does not move

The first draft scoped `Tokens avoided (≈)` to successful delegations. Applying
that breaks two tests, and one of them is not incidental:
`tests/test-metrics-summary.sh:77` is named **"mixed: tokens avoided sum across
sources"** and asserts `1240` over a fixture of one delegate row plus two
experiment rows. That assertion exists precisely to pin cross-source summation.
Redefining the headline repeals it, and the spec that proposed it never said so.

There is a second reason. Three lines below the headline sits a `Per-source:`
block printing delegate, embed and experiment subtotals that sum to 3,125,030.
A rescoped headline would contradict the block immediately beneath it.

So the headline keeps its meaning — gross local-model processing, all sources —
and the exclusions and the split are printed as indented sub-lines under it.
Nothing that consumes the current number changes.

### Verdicts pool: agent first, human fallback

The first draft used the agent tier alone and called the remainder "no verdict
recorded". That label is false for **18 delegations worth 37,812 tokens that
carry a human verdict**, ten of them recorded hits. A change whose entire
argument is label honesty cannot file a recorded verdict under "no verdict".

Pooling fixes it and costs nothing: agent verdict if present, else human. It
moves those 37,812 tokens out of the unknown bucket, the four buckets still sum
exactly to 2,814,223, and the genuinely-unverdicted count becomes 483 rather
than 501.

Agent-first is the right precedence. ADR 0015 assigns *usage* to the agent tier
and *quality* to the human one, and "were tokens avoided" is a usage question:
if the agent rewrote the draft, the frontier model produced the text regardless
of what a maintainer would have thought of it.

### The split is a usage figure, and it says so

The first draft justified the agent tier by claiming the two tiers "give
near-identical splits". That comparison was circular — it compared agent against
*pooled*, and pooled is 98% agent by construction. The human tier alone cannot
support this decomposition at all: it covers 20 of 1423 successful delegations.
ADR 0015's own 2026-06-18 update says why, recording that after the backfill
"the genuine human-quality sample is 3 rows, effectively empty."

That same update carries the caveat the first draft omitted while calling the
top bucket "a saving anyone can defend": the producing agent grading its own
output is biased toward "I used it, so it was good." The printed block therefore
labels itself as usage-derived rather than implying an audited saving.

### Where it goes

`metrics-summary.sh`, not a Grafana panel. Not because LogQL cannot join — it
can, and the review confirmed a working query returning 97,682 against a Python
cross-check — but because that query is "any agent hit exists" rather than
last-verdict-wins, and reproducing the real semantics would be a second copy of
a rule that already exists here.

**It cannot reuse the block at 249-251.** That block sits inside
`if (( n_feedback > 0 ))` at line 221, so reusing it prints nothing at all on a
feedback-free file — the exact outcome this spec's verification forbids. The
decomposition needs its own jq pass outside that guard. The first draft's "one
extra field in that projection and a sum" was wrong.

### Guards

Both failure modes are real and were reproduced:

- `[] | add` returns `null`, so an all-failed file prints `null` rather than 0.
  This bug is already live and visible today as `embed n=142 tokens≈null`.
- `100 / 0` aborts the whole jq program with exit 5. Under `set -uo pipefail`
  without `-e` the section silently vanishes and the script still exits 0.

Every sum takes `// 0` and every percentage is guarded on a non-zero
denominator.

## The two traps in the data

**Delegations can carry more than one verdict.** 44 carry multiple agent
verdicts, up to 5. Iterating feedback rows and adding the parent's tokens each
time double-counts. Iterate delegations and look up their last verdict. (The
first draft cited 636,579 as the figure this produces; the review could not
reproduce it under any variant and neither could I, so the number is dropped.
The trap stands without it.)

**A missing `source` means `delegate`.** 11 rows have no `source` field and
`metrics-summary.sh` already treats them as delegations (`src: .source //
"delegate"`). Filtering on `.source == "delegate"` drops them and the buckets
stop reconciling.

## Rejected: dropping `estimated_tokens_avoided` from the row

The per-row value correctly measures what the local model processed. The defect
is the unqualified rollup, not the field.

## Rejected: a single "true tokens avoided" number

It would need the 26% with no verdict assigned to one side, and there is no
honest way to do that. Four lines summing to the total say what is known and
what is not.

## What this does not close

The first draft claimed this closes the CLI/dashboard divergence #408
introduced. It does not, and the claim is narrowed rather than repeated:

- Of the three tokens-avoided panels, the new `successful delegations` sub-line
  matches `Tokens avoided` exactly. `Tokens avoided by project` reads 2,809,799
  because #408 also gave it `project!=""`, excluding the 3 project-less rows
  worth 4,424 — a separate divergence, and it folds `delegate-to-ollama` into
  `delegate-local` while the CLI still lists them separately.
- #408 filtered five other panel families (tier, project, recipe, backend,
  latency). The matching CLI sections — `Per-source`, `Per-backend`, `Per-tier`
  and `Total invocations` — remain unfiltered. Recorded as known-open rather
  than quietly left.

## Scope

`scripts/metrics-summary.sh` and `tests/test-metrics-summary.sh`. No schema
change, no re-sync, no change to what `delegate.sh` writes, and no change to any
existing printed value.

## Verification

- The four buckets sum exactly to the successful-delegation total, and the
  excluded lines plus that total sum exactly to the unchanged headline.
- A delegation carrying several verdicts is counted once, under its last.
- A delegation with only a human verdict lands in a real bucket, not "no verdict".
- A row with no `source` field lands in the delegate bucket.
- Scaffold is neither kept nor rewritten.
- A file with no feedback rows prints the headline, the exclusions, and the whole
  successful total as unverdicted — no missing section, no `null`, no exit 5.
- A file whose delegations all failed prints `0`, not `null`, and no percentage.
  (`p50=nullms` in `Per-source` is the same null class in a different block and
  is pre-existing; left open rather than widened into here.)
- The pre-existing cross-source test at line 77 still passes unmodified.
