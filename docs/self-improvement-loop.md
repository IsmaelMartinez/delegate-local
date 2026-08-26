# The self-improvement loop

The recipe library is supposed to accumulate calibration: every rejected draft
names a defect, and the defect becomes a guard so the next draft does not carry
it. In practice that only happened when a human asked "how are we doing", which
on 2026-08-26 meant a full day of twenty delegations, zero kept, and a defect
(a recipe returning its own example instead of an answer) that had been sitting
in the recorded reasons since the first call that morning.

This document is the procedure that closes the gap on a schedule. It is written
for a session woken by cron, but it is equally the checklist to follow by hand.

## Run the gate first

```bash
bash scripts/self-improve.sh
```

Exit 10 means nothing has happened since the last run. **Stop. Say nothing, do
not summarise, do not open a PR.** A loop that reports "no change" every two
hours is noise, and the quiet path deliberately prints nothing to stdout.

Exit 0 means there are new delegations and the evidence bundle is on stdout.
Exit 2 is a real error (no metrics file, no `jq`) and is worth surfacing.

Running it advances a watermark, so the next run sees only what is new. Use
`--peek` when you want to look without consuming the window.

## What the bundle gives you

Five sections, in the order you should read them.

The **verdict tally** is the headline: how many of the new delegations were
kept, used as a scaffold, or rewritten. The **per-recipe outcomes** section
ranks recipes by keep rate over a rolling window, worst first, so the recipe
worth your attention is the top line with a meaningful `n`. Ignore a 0% on
`n=1`; one delegation is not a signal.

The **deterministic check failures** section needs no interpretation. The
wrapper already decided the output broke a constraint the recipe declared, so
anything clustered here is the cheapest fix available.

The **rejected drafts** section is the substance. Each entry carries the
agent's free-text reason, and where both were captured, the draft the model
produced and the text that actually shipped, plus three objective signals:

- `DROPPED` — salient tokens (paths, backticked spans, hashes, issue refs,
  numbers) present in the shipped text and absent from the draft. These are
  the specific facts a human had to put back. A recipe edit aimed at these is
  calibrated; one aimed at "dropped every load-bearing fact" is a guess.
- `INVENTED` — present in the draft, absent from the shipped text. The
  hallucination signal.
- `SHAPE` — a list-vs-prose mismatch between the draft and what shipped.

The **capture coverage** line says how much of that you actually have. Drafts
are captured automatically; the shipped text only arrives when a caller passes
`--final` to `delegate-feedback.sh`. If coverage is low, raising it is a more
valuable fix than any recipe edit, because everything downstream depends on it.

## Choose one fix

One per run. A run that changes four recipes cannot tell you which change
moved the number.

Rank candidates by evidence, not by how annoying the defect looks:

1. A defect a deterministic check already flags, clustered on one recipe.
2. A defect named in two or more rejection reasons for the same recipe.
3. A single rejection that carries a draft/final pair showing a mechanical
   defect — a dropped anchor, an invented value, a list where prose shipped.

A single rejection with only a prose reason and no pair is **not** enough to
edit a recipe on. Note it and wait for the second one.

Then pick the shape of the fix, in this order of preference:

- **A deterministic check**, when the defect is mechanically detectable from
  the output alone. Prompt text asks the model to comply; a check knows whether
  it did. `no_example_echo`, `no_padding_tail` and `subject_max` all started as
  prompt instructions that did not hold.
- **A named guard in the recipe**, when the defect is about content the model
  can only get from the input. Give it a shouty name (`ANCHOR-PRESERVATION`,
  `NO-FACT-DROP`) and state the failure it prevents, because an unnamed rule
  buried in a list of ten gets ignored first.
- **A new recipe**, when the reasons say the recipe is being asked for a shape
  it explicitly excludes. Widening a closed shape usually costs the shape
  without buying the new one.
- **Nothing yet**, when the evidence is thin. This is a real option and the
  most common correct answer on a quiet day.

Two hard stops on thrash. Do not re-edit a recipe you edited in the previous
24 hours unless new evidence contradicts that edit — give the change time to
be measured. And if the same defect survives two prompt-text fixes, stop
rewording: the third attempt is a check, a new recipe, or a report saying the
prose tier cannot do this.

## Apply it

Work on a branch, never on `main`. This checkout is symlinked in as the
installed skill on both Claude profiles, so whatever branch it sits on is the
code every session on this machine runs.

Every recipe edit gets a dated entry in that recipe's `## Calibration notes`
saying what was observed, how many times, and what changed. That section is
how the next session knows a defect has already been attacked and with what.

Run the suites the change touches (`tests/test-delegate.sh`,
`tests/test-prompts-library.sh`, `tests/test-self-improve.sh`), open a PR, and
stop. **Never merge.** Opening a PR is a request for review. Report the PR
number and the one-line reason it exists.

## Do not fake progress

Quote the `n` beside every rate. At this corpus size one delegation moves a
percentage by several points, and a keep rate over `n=3` is a rumour.

Never claim a fix worked without a measurement taken after it landed. The
honest form is "this landed on <date>, re-measure after ~10 more calls on that
recipe". A previous era of this corpus was polluted by exactly this kind of
optimism, which is why it was reset (ADR 0028).

If the loop finds nothing to fix on a run, that is a successful run.
