# Let the sweep sample what the agent graded itself on: design

**Date:** 2026-08-19
**Follows:** #416, which restored `verdict-sweep.sh` but left this gap open.

An adversarial review of the first draft found six blockers. It destroyed the
evidence section outright, showed the proposed sampler pointed away from the
bias it was built to measure, and confirmed the incoherence in the metric that I
had already flagged. Each correction is recorded rather than quietly applied.

## The gap

`verdict-sweep.sh` defines its work set as "a successful delegation with **no
feedback row of any tier**". An agent verdict therefore marks a row as done, and
the sweep can never offer it to a human.

That is right for coverage and wrong for calibration. ADR 0015's 2026-06-18
update states the problem: the producing agent grading its own output "is biased
toward 'I used it, so it was good'", and what is needed is "a small periodic
human sample used only to calibrate the verifier". The rows worth sampling are
exactly the ones the agent already judged, and those are the rows the sweep
excludes by construction.

## The evidence, corrected

The first draft opened with two delegations carrying both a human and an agent
verdict, disagreeing on both, and quoted one at length as the agent reporting
"used verbatim with zero edits" for output that needed a hand-strip.

**That evidence does not exist.** `verdict_source` shipped on 2026-06-15 (#308).
Both rows were written on 2026-05-09 and 2026-05-11, five weeks earlier, when
the field and the agent question did not exist. ADR 0015's backfill retagged
every reasonless-tier row recorded within 300 s of its delegation, and:

```
delegation 2026-05-09  "agent" row +30s   INSIDE 300s    "human" row +36359s  outside
delegation 2026-05-11  "agent" row +36s   INSIDE 300s    "human" row +2578s   outside
```

The tier split is entirely manufactured by that threshold. No agent ever
answered the agent question on either row, so the first draft described a
self-report that was never made. The second pair is worse still: the human's
reason cites a stall "past 30s" against a row whose own telemetry records
`duration_ms=12246`.

What the data does support is narrower and sufficient. Read as the repo reads
them, those two rows are verdict **revisions**, and revision is routine: of 46
multi-verdict delegations, 13 flip, and **6 flip hit→miss entirely within the
agent tier** — same question, same actor, changed answer on a second look. That
is a reason to build a second-look path. It is not evidence of cross-tier
disagreement, and this spec no longer claims any.

The honest state of the calibration signal is that **there are zero pairs
recorded since the tiers became real.** The mechanism to create one does not
exist. That is the whole argument.

## Decision

### `verdict-sweep.sh --calibrate`

Offers successful delegations that carry an **agent hit** and no human verdict,
for a human verdict. Same recorder call, no `--source`, so what lands is
human-tier and sits beside the agent row rather than replacing it. (Verified:
the 300 s stale guard lives only on the implicit path, and `--ts` records
cleanly against a 102-day-old row.)

The default mode is untouched.

### Eligibility is agent-**hit**, not agent-anything

This is the correction that matters most. The first draft sampled any
agent-verdicted row, most-recent-first, and argued recency was better than
random. Measured, that sampler points away from the bias:

```
lifetime eligible   n=920  73% agent-hit   25 recipes  5 tiers
most recent 5       n=5    20% agent-hit    1 recipe   1 tier
```

The bias under test is "I used it, so it was good" — observable **only** on rows
the agent claimed as hits. An unrestricted recent sample draws 4 in 5 from rows
where the agent already admitted a miss, where there is no self-flattery left to
catch, and collapses to a single recipe and tier.

Restricting eligibility to agent-hit keeps the recall argument (which is sound:
outputs are never stored, so a human can only assess a delegation they still
remember) and restores the targeting:

```
recent 5, agent-hit only   n=5   100% agent-hit   3 recipes
```

`agent = scaffold` rows are excluded too — 21 of them. The sweep offers
`h/m/s/q` with no key for scaffold, so a human cannot record that outcome, and
any human verdict on such a row would be forced into a false comparison.
Excluding them is what lets the fourth key stay out of scope without leaving an
unanswerable pair behind.

### The window widens for this mode

The sweep defaults to 24 h, which holds 2 eligible rows. Calibration is a
periodic retrospective, not daily hygiene:

```
agent-hit eligible:  24h=2   48h=5   7d=28   30d=138   lifetime=680
```

`--calibrate` therefore defaults to 168 h, still overridable by
`DELEGATE_SWEEP_WINDOW_HOURS`. `--sample N` (default 5) caps the offer.

### It shows the agent's claim

`metrics.jsonl` stores char counts, never output — ADR 0016: "the evidence is
gone by design". The agent's own `reason` is the only surviving description, and
65% of eligible rows carry one. It is truncated to 100 characters, matching the
existing convention in `delegate-feedback.sh`'s MISS nudge; the longest live
reason is 937 characters and would otherwise destroy the prompt line.

The human is still asked the human question, not "do you agree" — collapsing the
two would put an answer to the agent's question into the human tier, the
conflation #408 and #416 both removed.

### The metric is directional, and scoped

The first draft added a symmetric agreement rate. That is incoherent, for the
reason the spec itself gives: if the two tiers answer different questions then
`human != agent` is not disagreement, it is two compatible facts, and an
equality test over them measures nothing.

Because eligibility is now agent-hit only, every pair this produces has
`agent = hit`, and the meaningful quantity is one conditional:

> of delegations the agent shipped, how many did a person judge not good —
> **P(human = miss | agent = hit)**

That is the self-flattery rate, and the two directions are not symmetric: an
agent shipping something a human rejects is the failure ADR 0015 predicts, while
an agent rewriting something a human would have kept is merely wasteful.

`metrics-summary.sh` prints it in the feedback block, which already holds
`$hmap` and `$amap`, so it is a derived line and not a new pass. Two scoping
facts are stated rather than assumed: it is computed over `$rx` (recipe
delegations), matching every other line under that heading, which puts the one
bare/no-recipe artifact row out of scope; and it prints n inline, because the
only two existing pairs are the backfill artifacts above and will skew a small
sample until real ones accumulate.

## Rejected: making `--calibrate` the default

The untracked backlog is real work and the coverage number depends on it.

## Rejected: random sampling across the full history

Outputs are not stored, so a row the human cannot recall yields a guessed
verdict, and a guessed verdict entering a 20-row pool is worse than none.
Stratifying inside the recall window is the middle option the first draft
missed, and agent-hit restriction is the stratification that matters.

## Found while implementing

Two things the spec did not anticipate, both fixed here.

**A latent shift bug in `metrics-summary.sh`.** `add` over delegate rows that
carry no `estimated_tokens_avoided` returns null, which `@tsv` renders as an
empty field. Tab is IFS whitespace, so bash `read` collapses the resulting
double-tab into one delimiter and every later column shifts left: a sparse file
reported `delegate=0, experiment=4, errors=4` when the truth was `4, 0, 0`. Three
numbers wrong at once, silently. Guarded with `// 0` and pinned. This is the same
null class recorded as known-open in the #412 spec; this is a concrete
manifestation of it, so it is fixed rather than deferred again.

**A clock race in the new test.** The sample-ordering fixture computed its
timestamps once to write the rows and again to assert against them, so a second
ticking over between the two made them disagree. Caught by an intermittent
failure, not by the first run. Stamps are captured once and reused.

## Implementation notes the first draft got wrong

- The metrics file is **not** strictly chronological — 8 adjacent out-of-order
  pairs — so "most recent" requires an explicit `sort_by(.ts) | reverse`, never
  a tail.
- A 4-variable `IFS=$'\t' read` absorbs surplus columns into the last variable,
  so adding agent verdict and reason to a shared emitter would silently corrupt
  the default mode's `model=` display. Two emitters, or emitter and read change
  together.
- `-h` prints `sed -n '2,9p'`, which stops before the usage line; it needs
  widening when flags are added.

## Verification

- `--calibrate` offers an agent-hit row with no human verdict.
- It does not offer: an unjudged row, an agent-miss row, an agent-scaffold row,
  or a row that already has a human verdict. Asserted individually.
- The default mode does not offer an agent-verdicted row — the two sets stay
  disjoint, asserted both ways.
- The recorded verdict is human-tier and coexists with the agent row.
- `--sample N` caps and takes the most recent by `ts`, not by file order.
- A reason over 100 characters is truncated; a reasonless row still renders.
- `metrics-summary.sh` prints the conditional only when a pair exists, over
  `$rx`, naming n.
