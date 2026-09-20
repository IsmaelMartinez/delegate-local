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

Six sections, in the order you should read them.

The **verdict tally** is the headline: how many of the new delegations were
kept, used as a scaffold, or rewritten, and the usable rate over all of them.
Every verdict is the agent's own record of what it did with its draft, and
that is the one tier there is (ADR 0030): the agent that used or rewrote the
output is the judge, and the reason plus the draft/final pair is what turns a
verdict into evidence.

The **per-recipe outcomes** section ranks recipes by usable rate — kept plus
scaffold — over a rolling window, worst first, so the recipe worth your
attention is the top line with a meaningful `n`. Usable rather than kept alone,
because a draft the agent edited and shipped did most of its job, while a
recipe whose drafts are all thrown away is a different and worse problem, and
a kept-only rate cannot tell the two apart. `commit-message` read 0% kept and
80% usable on the same 25 rows the day this changed. Ignore a 0% on `n=1`; one
delegation is not a signal.

The **per-template outcomes** section appears only for a recipe that ran
under more than one template in the window: one line per template, newest
first, with the hash, the first row's timestamp and the same counts. Rows
from before the hash was recorded are their own `(unhashed)` line. This is
the post-merge read for an edit that landed, and the revert signal (see
"Revert when the online read disagrees" below); when no recipe changed
template there is nothing to read and the section is absent.

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
- `INVENTED` — present in the draft, absent from the shipped text, on a
  rejection where the human ALSO put tokens back. Something in the draft was
  substituted, so this is the hallucination signal.
- `CUT` — present in the draft, absent from the shipped text, on a rejection
  where the human put nothing back. Material was removed and nothing was
  substituted for it, usually a length edit. It says nothing about whether the
  draft was true, so do not read a `CUT` list as invention. Five of the seven
  pairs in the window to 2026-08-27 were this, every one of them a
  `commit-message` body trimmed to the profile's word cap.
- `SHAPE` — a list-vs-prose mismatch between the draft and what shipped.

Where the delegation was a recipe call made after #516, the rendered input the
model saw sits beside the draft as `<stem>.input.txt`, the bundle names it, and
the signals are scored against what the caller actually supplied rather than
against the draft alone:

- `DROPPED` narrows to anchors the input supplied: present in the input and
  the shipped text, absent from the draft. That is the model losing a fact it
  was given, which is what a recipe guard can be aimed at.
- `ADDED` — anchors in the shipped text that neither the input nor the draft
  had. The human brought them from outside the delegation, so they say
  nothing about the recipe; without the input they would have counted as
  `DROPPED`.
- `UNUSED` — salient tokens present in the input and absent from the shipped
  text: the anchors the caller handed over that ended up nowhere, which for
  the reply recipes is the "handed the input back" family measured directly.
- `ECHOED` — input sentences the draft reproduced as written, with the count.
  It is `no_context_echo`'s comparison (sentence unit, `echo_normalise`
  rules, 40-character floor) run after the fact, so a rejection that says
  "restated the facts" carries the sentences it means.

The recipe's own template lines are subtracted from the input before either
is computed, so an example path or issue number the recipe carries is never
reported as a supplied anchor. Rows from before the input was captured print
as they always did.

The **capture coverage** line says how much of that you actually have. Drafts
and inputs are captured automatically. The shipped text arrives either because
a caller passed `--final` to `delegate-feedback.sh`, or because the boundary hook saw
the post: when a `gh`/`glab` post is credited to a delegation, that post is
that delegation's shipped form, so the hook stores it under the draft's own
stem and the verdict adopts it. A final that arrived that way is marked
`captured from the post` in the bundle, because the hook runs BEFORE the post
and therefore stores what was about to go out rather than what demonstrably
did. If coverage is low, raising it is a more valuable fix than any recipe
edit, because everything downstream depends on it.

## Choose one fix

One per run. A run that changes four recipes cannot tell you which change
moved the number.

Rank candidates by evidence, not by how annoying the defect looks:

1. A defect a deterministic check already flags, clustered on one recipe.
2. A defect named in two or more rejection reasons for the same recipe.
3. A single rejection that carries a draft/final pair showing a mechanical
   defect — a dropped anchor, an invented value, a list where prose shipped,
   a supplied sentence handed back.

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

## Gate the fix with a replay

A fix chosen on the evidence above is a hypothesis until it has been
measured, and the online read is too slow to be the measurement: at eight to
ten calls a day on a reply recipe, telling a fifteen-point lift from noise
takes weeks per edit. The replay is the measurement. Every recipe call since
2026-09-19 stores its structured inputs (stdin, each `--var`, the prompt) as
`<stem>.inputs.json` beside the draft, and every row carries `template_sha`,
so a stored case can be rendered again under another template.
`replay-recipe.sh` does that for the template that is live and the one you
edited, sends both through `delegate.sh` (so the checks and the retry are
production's, on the tier the case was made on), and scores each output the
way the bundle scores a pair: the wrapper's failed checks, the supplied
anchors the shipped text carried and the output dropped, the supplied
anchors the output carries that the shipped text does not (`over`: the
facts handed back in the model's own sentences, the supplied subset of
what the bundle lists as `CUT` or `INVENTED`, which nothing else
measures), the anchors the output carries that neither the inputs nor the
shipped text do, the piped sentences the output hands back beyond those
the shipped text itself carries, a list-versus-prose mismatch, and a
length flag for an output under a quarter or over four times the shipped
text's word count. A kept delegation is a case too, with its draft as the
reference, and the scoring is symmetric on it: an edit that disturbs an
output the agent shipped unedited, by dropping or by adding, loses that
case. `over` is there because the first pass to use the gate (2026-09-20)
found six rejected `maintainer-review-reply` drafts scoring zero on the
five measures that then existed: they carried 40-100% of the facts'
anchors against shipped replies carrying a median 6%, echoed no sentence
verbatim and matched the shape, and the maintainer had rejected all six
for describing the contributor's own change back to them. Without it the
gate could not see the reply recipes' dominant defect and charged its cure
as `dropped`. The length flag came with it: `over` is unbounded and
`dropped` is bounded by the reference's own anchors, so against
anchor-poor replies an output that says nothing sits at zero anchor
distance and wins every case, and a rise in length flags holds the
verdict at INCONCLUSIVE exactly as a rise in failed checks does.

The champion is the recipe as committed on `main`, read out of git into a
temp dir, not the file in your checkout: you edit on a branch in this same
checkout, so the working file is the candidate. Pass `--champion DIR` to
compare against something else.

```bash
bash scripts/replay-recipe.sh --recipe maintainer-reply --candidate /path/to/worktree/prompts
```

Read the verdict line. `ACCEPT` is more wins than losses at p < 0.05 on a
one-sided sign test with no rise in failed checks: six wins to none, eight to
one, ten to two. `REJECT` is the mirror. `INCONCLUSIVE` means the edit did
not separate the arms on the cases there are, and the right response is
usually to leave the recipe alone: the edit is not wrong, it is unmeasured,
and the commonest cause is that it targets a defect the cases do not carry.
The "newest third" line is the overfitting check: a candidate that wins only
on the older cases the reasons were read from has learned those cases, not
the defect.

Greedy decoding is deterministic on this backend, so one pass per arm is the
whole measurement. Outputs are cached by case and template hash, so a re-run
against the same edit sends nothing, and a case whose stored template hash
matches the champion's is scored from its stored draft without a call.
Expect three to eight seconds per case per arm otherwise; `--limit` caps the
case count (default 40, newest first).

Quote the replay's summary and verdict lines in the PR body, with the n. A
recipe edit with no replay line, or an inconclusive one, is a proposal, not a
fix, and the PR should say so.

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

## Revert when the online read disagrees

The replay is the pre-merge gate; the online read is the post-merge one.
Once an edit has landed, every row the recipe writes carries the new
template hash, and the bundle's per-template section prints the recipe's
outcomes under the new hash beside the previous one, with the n on each.
Read it once the new template has thirty tracked rows, not before: below
that a rate is a rumour, and the thrash rule already forbids a second edit
inside 24 hours.

If the new template's usable rate sits below the previous one's by more than
the margin that n can resolve (at thirty rows a side, roughly twenty-five
points; the replay's sign test was the fine instrument, this is the coarse
one), open a revert PR, and write the failure into the recipe's calibration
notes as a dated entry naming both hashes, the n on each side and the rates,
so the next session does not try the same edit again. A revert is a normal
outcome of the loop, not an incident. When the online read agrees with the
replay, say so in the next bundle and move on.

## Do not fake progress

Quote the `n` beside every rate. At this corpus size one delegation moves a
percentage by several points, and a rate over `n=3` is a rumour. The rate is
the producing agent grading its own output, which skews toward "I used it, so
it was good"; the reason and the draft/final pair are what keep it honest, so
a hit rate with thin capture coverage is a weaker claim than the number
suggests.

Never claim a fix worked without a measurement taken after it landed. The
honest form is "this landed on <date>, re-measure after ~10 more calls on that
recipe". A previous era of this corpus was polluted by exactly this kind of
optimism, which is why it was reset (ADR 0028).

If the loop finds nothing to fix on a run, that is a successful run.
